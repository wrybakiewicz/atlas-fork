//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.16;

import {IExecutionEnvironment} from "../interfaces/IExecutionEnvironment.sol";

import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

import "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {SafetyLocks} from "./SafetyLocks.sol";
import {SearcherWrapper} from "./SearcherWrapper.sol";
import {ProtocolVerifier} from "./ProtocolVerification.sol";

import "../types/CallTypes.sol";
import "../types/EscrowTypes.sol";
import "../types/LockTypes.sol";
import "../types/VerificationTypes.sol";

import {EscrowBits} from "../libraries/EscrowBits.sol";
import {CallChainProof} from "../libraries/CallVerification.sol";
import {CallVerification} from "../libraries/CallVerification.sol";

// import "forge-std/Test.sol";

contract Escrow is ProtocolVerifier, SafetyLocks, SearcherWrapper {
    using ECDSA for bytes32;
    using CallVerification for CallChainProof;

    uint32 public immutable escrowDuration;

    // NOTE: these storage vars / maps should only be accessible by *signed* searcher transactions
    // and only once per searcher per block (to avoid user-searcher collaborative exploits)
    // EOA Address => searcher escrow data
    mapping(address => SearcherEscrow) private _escrowData;

    constructor(
        uint32 escrowDurationFromFactory //,
            //address _atlas
    ) SafetyLocks() {
        escrowDuration = escrowDurationFromFactory;
    }

    ///////////////////////////////////////////////////
    /// EXTERNAL FUNCTIONS FOR SEARCHER INTERACTION ///
    ///////////////////////////////////////////////////
    function deposit(address searcherMetaTxSigner) external payable returns (uint256 newBalance) {
        // NOTE: The escrow accounting system cannot currently handle deposits made mid-transaction.
        EscrowKey memory escrowKey = _escrowKey;
        require(
            escrowKey.approvedCaller == address(0) && escrowKey.makingPayments == false
                && escrowKey.paymentsComplete == false && escrowKey.callIndex == uint8(0) && escrowKey.callMax == uint8(0)
                && escrowKey.lockState == uint16(0) && escrowKey.gasRefund == uint32(0),
            "ERR-E001 AlreadyInitialized"
        );

        _escrowData[searcherMetaTxSigner].total += uint128(msg.value);
        newBalance = uint256(_escrowData[searcherMetaTxSigner].total);
    }

    function nextSearcherNonce(address searcherMetaTxSigner) external view returns (uint256 nextNonce) {
        nextNonce = uint256(_escrowData[searcherMetaTxSigner].nonce) + 1;
    }

    ///////////////////////////////////////////////////
    ///             INTERNAL FUNCTIONS              ///
    ///////////////////////////////////////////////////
    function _executeStagingCall(
        ProtocolCall calldata protocolCall,
        UserCall calldata userCall,
        CallChainProof memory proof,
        address environment
    ) internal stagingLock(protocolCall, environment) returns (bytes memory stagingReturnData) {
        stagingReturnData = IExecutionEnvironment(environment).stagingWrapper{value: msg.value}(proof, userCall);
    }

    function _executeUserCall(UserCall calldata userCall, address environment)
        internal
        userLock(userCall, environment)
        returns (bytes memory userReturnData)
    {
        userReturnData = IExecutionEnvironment(environment).userWrapper(userCall);
    }

    function _executeSearcherCall(
        SearcherCall calldata searcherCall,
        CallChainProof memory proof,
        bool auctionAlreadyComplete,
        address environment
    ) internal returns (bool) {
        // Set the gas baseline
        uint256 gasWaterMark = gasleft();
        uint256 gasRebate;

        // Open the searcher lock
        _openSearcherLock(searcherCall.metaTx.to, environment);

        // Verify the transaction.
        (uint256 result, uint256 gasLimit, SearcherEscrow memory searcherEscrow) =
            _verify(searcherCall, gasWaterMark, auctionAlreadyComplete);

        SearcherOutcome outcome;
        uint256 escrowSurplus;

        // If there are no errors, attempt to execute
        if (EscrowBits.canExecute(result)) {
            // Execute the searcher call
            (outcome, escrowSurplus) = _searcherCallWrapper(searcherCall, proof, gasLimit, environment);

            unchecked {
                searcherEscrow.total += uint128(escrowSurplus);
            }

            result |= 1 << uint256(outcome);

            if (EscrowBits.executedWithError(result)) {
                result |= 1 << uint256(SearcherOutcome.ExecutionCompleted);
            } else if (EscrowBits.executionSuccessful(result)) {
                // first successful searcher call that paid what it bid
                auctionAlreadyComplete = true; // cannot be reached if bool is already true
                result |= 1 << uint256(SearcherOutcome.ExecutionCompleted);
            }
        }

        // emit event
        if (EscrowBits.emitEvent(searcherEscrow)) {
            emit SearcherTxResult(
                searcherCall.metaTx.to,
                searcherCall.metaTx.from,
                EscrowBits.canExecute(result),
                outcome == SearcherOutcome.Success,
                EscrowBits.canExecute(result) ? searcherEscrow.nonce - 1 : searcherEscrow.nonce,
                result
            );
        }

        // Update the searcher's escrow balances
        if (EscrowBits.updateEscrow(result)) {
            gasRebate = _update(searcherCall.metaTx, searcherEscrow, gasWaterMark, result);
        }

        // Close the searcher lock
        _closeSearcherLock(searcherCall.metaTx.to, environment, gasRebate);

        return auctionAlreadyComplete;
    }

    // TODO: who should pay gas cost of MEV Payments?
    // TODO: Should payment failure trigger subsequent searcher calls?
    // (Note that balances are held in the execution environment, meaning
    // that payment failure is typically a result of a flaw in the
    // ProtocolControl contract)
    function _executePayments(
        ProtocolCall calldata protocolCall,
        BidData[] calldata winningBids,
        PayeeData[] calldata payeeData,
        address environment
    ) internal paymentsLock(environment) {
        // process protocol payments
        try IExecutionEnvironment(environment).allocateRewards(winningBids, payeeData) {}
        catch {
            emit MEVPaymentFailure(protocolCall.to, protocolCall.callConfig, winningBids, payeeData);
        }
    }

    function _executeVerificationCall(
        ProtocolCall calldata protocolCall,
        CallChainProof memory proof,
        bytes memory stagingReturnData,
        bytes memory userReturnData,
        address environment
    ) internal verificationLock(protocolCall.callConfig, environment) {
        proof = proof.addVerificationCallProof(protocolCall.to, stagingReturnData, userReturnData);

        IExecutionEnvironment(environment).verificationWrapper(proof, stagingReturnData, userReturnData);
    }

    function _executeUserRefund(address userCallFrom) internal {
        uint256 gasRebate = uint256(_escrowKey.gasRefund) * tx.gasprice;

        /*
        emit UserTxResult(
            userCallFrom,
            0,
            gasRebate
        );
        */

        SafeTransferLib.safeTransferETH(userCallFrom, gasRebate);
    }

    function _update(
        SearcherMetaTx calldata metaTx,
        SearcherEscrow memory searcherEscrow,
        uint256 gasWaterMark,
        uint256 result
    ) internal returns (uint256 gasRebate) {
        unchecked {
            uint256 gasUsed = gasWaterMark - gasleft();

            if (result & EscrowBits._FULL_REFUND != 0) {
                gasRebate = gasUsed + (metaTx.data.length * 16);

                // TODO: figure out what is fair for this (or if it just doesnt happen?)
            } else if (result & EscrowBits._EXTERNAL_REFUND != 0) {
                // TODO: simplify/fix formula for calldata - verify.
                gasRebate = gasUsed + (metaTx.data.length * 16);
            } else if (result & EscrowBits._CALLDATA_REFUND != 0) {
                gasRebate = (metaTx.data.length * 16);
            } else if (result & EscrowBits._NO_USER_REFUND != 0) {
                // pass
            } else {
                revert("ERR-SE72 UncoveredResult");
            }

            if (gasRebate != 0) {
                // Calculate what the searcher owes
                gasRebate *= tx.gasprice;

                gasRebate = gasRebate > searcherEscrow.total ? searcherEscrow.total : gasRebate;

                searcherEscrow.total -= uint128(gasRebate);

                // NOTE: This will cause an error if you are simulating with a gasPrice of 0
                gasRebate /= tx.gasprice;

                // save the escrow data back into storage
                _escrowData[metaTx.from] = searcherEscrow;
            }
        }
    }

    function _verify(SearcherCall calldata searcherCall, uint256 gasWaterMark, bool auctionAlreadyComplete)
        internal
        view
        returns (uint256 result, uint256 gasLimit, SearcherEscrow memory searcherEscrow)
    {
        // verify searcher's signature
        if (_verifySignature(searcherCall.metaTx, searcherCall.signature)) {
            // verify the searcher has correct usercalldata and the searcher escrow checks
            (result, gasLimit, searcherEscrow) = _verifySearcherCall(searcherCall);
        } else {
            (result, gasLimit) = (1 << uint256(SearcherOutcome.InvalidSignature), 0);
            // searcherEscrow returns null
        }

        result = _searcherCallPreCheck(
            result, gasWaterMark, tx.gasprice, searcherCall.metaTx.maxFeePerGas, auctionAlreadyComplete
        );
    }

    function _getSearcherHash(SearcherMetaTx calldata metaTx) internal pure returns (bytes32 searcherHash) {
        return keccak256(
            abi.encode(
                SEARCHER_TYPE_HASH,
                metaTx.from,
                metaTx.to,
                metaTx.value,
                metaTx.gas,
                metaTx.nonce,
                metaTx.userCallHash,
                metaTx.maxFeePerGas,
                metaTx.bidsHash,
                keccak256(metaTx.data)
            )
        );
    }

    // TODO: make a more thorough version of this
    function _verifySignature(SearcherMetaTx calldata metaTx, bytes calldata signature) internal view returns (bool) {
        /* COMMENTED OUT FOR TESTING
        address signer = _hashTypedDataV4(
            _getSearcherHash(metaTx)
        ).recover(signature);
        
        return signer == metaTx.from;
        */
        return true;
    }

    function _verifyBids(bytes32 bidsHash, BidData[] calldata bids) internal pure returns (bool validBid) {
        // NOTE: this should only occur after the searcher's signature on the bidsHash is verified
        validBid = keccak256(abi.encode(bids)) == bidsHash;
    }

    function _verifySearcherCall(SearcherCall calldata searcherCall)
        internal
        view
        returns (uint256 result, uint256 gasLimit, SearcherEscrow memory searcherEscrow)
    {
        searcherEscrow = _escrowData[searcherCall.metaTx.from];

        if (searcherCall.metaTx.nonce <= uint256(searcherEscrow.nonce)) {
            result |= 1 << uint256(SearcherOutcome.InvalidNonceUnder);
        } else if (searcherCall.metaTx.nonce > uint256(searcherEscrow.nonce) + 1) {
            result |= 1 << uint256(SearcherOutcome.InvalidNonceOver);

            // TODO: reconsider the jump up for gapped nonces? Intent is to mitigate dmg
            // potential inflicted by a hostile searcher/builder.
            searcherEscrow.nonce = uint32(searcherCall.metaTx.nonce);
        } else {
            ++searcherEscrow.nonce;
        }

        if (searcherEscrow.lastAccessed >= uint64(block.number)) {
            result |= 1 << uint256(SearcherOutcome.PerBlockLimit);
        } else {
            searcherEscrow.lastAccessed = uint64(block.number);
        }

        if (!_verifyBids(searcherCall.metaTx.bidsHash, searcherCall.bids)) {
            result |= 1 << uint256(SearcherOutcome.InvalidBidsHash);
        }

        gasLimit = (100)
            * (
                searcherCall.metaTx.gas < EscrowBits.SEARCHER_GAS_LIMIT
                    ? searcherCall.metaTx.gas
                    : EscrowBits.SEARCHER_GAS_LIMIT
            ) / (100 + EscrowBits.SEARCHER_GAS_BUFFER) + EscrowBits.FASTLANE_GAS_BUFFER;

        uint256 gasCost = (tx.gasprice * gasLimit) + (searcherCall.metaTx.data.length * 16 * tx.gasprice);

        // see if searcher's escrow can afford tx gascost
        if (gasCost > searcherEscrow.total - searcherEscrow.escrowed) {
            // charge searcher for calldata so that we can avoid vampire attacks from searcher onto user
            result |= 1 << uint256(SearcherOutcome.InsufficientEscrow);
        }

        // subtract out the gas buffer since the searcher's metaTx won't use it
        gasLimit -= EscrowBits.FASTLANE_GAS_BUFFER;

        // Verify that we can lend the searcher their tx value
        if (searcherCall.metaTx.value > address(this).balance) {
            result |= 1 << uint256(SearcherOutcome.CallValueTooHigh);
        }
    }

    receive() external payable {}

    fallback() external payable {
        revert(); // no untracked balance transfers plz. (not that this fully stops it)
    }

    // BITWISE STUFF
    function _searcherCallPreCheck(
        uint256 result,
        uint256 gasWaterMark,
        uint256 txGasPrice,
        uint256 maxFeePerGas,
        bool auctionAlreadyComplete
    ) internal pure returns (uint256) {
        if (auctionAlreadyComplete) {
            result |= 1 << uint256(SearcherOutcome.LostAuction);
        }

        if (gasWaterMark < EscrowBits.VALIDATION_GAS_LIMIT + EscrowBits.SEARCHER_GAS_LIMIT) {
            // Make sure to leave enough gas for protocol validation calls
            result |= 1 << uint256(SearcherOutcome.UserOutOfGas);
        }

        if (txGasPrice > maxFeePerGas) {
            result |= 1 << uint256(SearcherOutcome.GasPriceOverCap);
        }

        return result;
    }
}
