// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";
import { ERC20 } from "solmate/tokens/ERC20.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";
import { SolverOperation } from "src/contracts/types/SolverCallTypes.sol";
import { UserOperation } from "src/contracts/types/UserCallTypes.sol";
import { DAppOperation, DAppConfig } from "src/contracts/types/DAppApprovalTypes.sol";
import { SwapIntent, SwapIntentInvertBidDAppControl } from "src/contracts/examples/intents-example/SwapIntentInvertBidDAppControl.sol";
import { SolverBaseInvertBid } from "src/contracts/solver/SolverBaseInvertBid.sol";

contract SwapIntentTest is BaseTest {
    SwapIntentInvertBidDAppControl public swapIntentControl_bidKnown_solverBidRetreivalNotRequired;
    SwapIntentInvertBidDAppControl public swapIntentControl_bidKnown_solverBidRetreivalRequired;
    SwapIntentInvertBidDAppControl public swapIntentControl_bidFind_solverBidRetreivalNotRequired;
    SwapIntentInvertBidDAppControl public swapIntentControl_bidFind_solverBidRetreivalRequired;

    Sig public sig;

    ERC20 DAI = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address DAI_ADDRESS = address(DAI);

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function setUp() public virtual override {
        BaseTest.setUp();

        // Creating new gov address (SignatoryActive error if already registered with control)
        governancePK = 11_112;
        governanceEOA = vm.addr(governancePK);

        // Deploy new SwapIntent Controls from new gov and initialize in Atlas
        vm.startPrank(governanceEOA);
        swapIntentControl_bidKnown_solverBidRetreivalNotRequired = new SwapIntentInvertBidDAppControl(address(atlas), false, false);
        swapIntentControl_bidKnown_solverBidRetreivalRequired = new SwapIntentInvertBidDAppControl(address(atlas), false, true);
        swapIntentControl_bidFind_solverBidRetreivalNotRequired = new SwapIntentInvertBidDAppControl(address(atlas), true, false);
        swapIntentControl_bidFind_solverBidRetreivalRequired = new SwapIntentInvertBidDAppControl(address(atlas), true, true);

        atlasVerification.initializeGovernance(address(swapIntentControl_bidKnown_solverBidRetreivalNotRequired));
        atlasVerification.initializeGovernance(address(swapIntentControl_bidKnown_solverBidRetreivalRequired));
        atlasVerification.initializeGovernance(address(swapIntentControl_bidFind_solverBidRetreivalNotRequired));
        atlasVerification.initializeGovernance(address(swapIntentControl_bidFind_solverBidRetreivalRequired));
        vm.stopPrank();

        // Deposit ETH from Searcher signer to pay for searcher's gas
        // vm.prank(solverOneEOA);
        // atlas.deposit{value: 1e18}();
    }

    function testAtlasSwapIntentInvertBid() public {
        address control = address(swapIntentControl_bidKnown_solverBidRetreivalNotRequired);

        uint256 amountUserBuys = 20e18;
        uint256 maxAmountUserSells = 10e18;
        uint256 solverBidAmount = 1e18;

        SwapIntent memory swapIntent = createSwapIntent(amountUserBuys, maxAmountUserSells);
        SimpleRFQSolverInvertBid rfqSolver = deployAndFundRFQSolver(swapIntent);
        address executionEnvironment = createExecutionEnvironment(control);
        UserOperation memory userOp = buildUserOperation(control, swapIntent);
        SolverOperation memory solverOp = buildSolverOperation(control, userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmount);
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = solverOp;
        DAppOperation memory dAppOp = buildDAppOperation(control, userOp, solverOps);

        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); 
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.maxAmountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);
        assertTrue(userWethBalanceBefore >= swapIntent.maxAmountUserSells, "Not enough starting WETH");

        approveAtlasAndExecuteSwap(swapIntent, userOp, solverOps, dAppOp);

        // Check user token balances after
        assertEq(WETH.balanceOf(userEOA), userWethBalanceBefore - solverBidAmount, "Did not spend WETH == solverBidAmount");
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }

    function testAtlasSwapIntentInvertBidMultipleSolvers() public {
        address control = address(swapIntentControl_bidKnown_solverBidRetreivalNotRequired);

        uint256 amountUserBuys = 20e18;
        uint256 maxAmountUserSells = 10e18;

        uint256 solverBidAmountOne = 1e18;
        uint256 solverBidAmountTwo = 2e18;

        SwapIntent memory swapIntent = createSwapIntent(amountUserBuys, maxAmountUserSells);
        SimpleRFQSolverInvertBid rfqSolver = deployAndFundRFQSolver(swapIntent);
        address executionEnvironment = createExecutionEnvironment(control);
        UserOperation memory userOp = buildUserOperation(control, swapIntent);
        SolverOperation memory solverOpOne = buildSolverOperation(control, userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmountOne);
        SolverOperation memory solverOpTwo = buildSolverOperation(control, userOp, swapIntent, executionEnvironment, address(rfqSolver), solverBidAmountTwo);
        
        SolverOperation[] memory solverOps = new SolverOperation[](2);
        solverOps[0] = solverOpOne;
        solverOps[1] = solverOpTwo;
        DAppOperation memory dAppOp = buildDAppOperation(control, userOp, solverOps);

        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); 
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.maxAmountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);
        assertTrue(userWethBalanceBefore >= swapIntent.maxAmountUserSells, "Not enough starting WETH");

        approveAtlasAndExecuteSwap(swapIntent, userOp, solverOps, dAppOp);

        // Check user token balances after
        assertEq(WETH.balanceOf(userEOA), userWethBalanceBefore - solverBidAmountOne, "Did not spend WETH == solverBidAmountOne");
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");
    }

    function createSwapIntent(uint256 amountUserBuys, uint256 maxAmountUserSells) internal view returns (SwapIntent memory) {
        return SwapIntent({
            tokenUserBuys: DAI_ADDRESS,
            amountUserBuys: amountUserBuys,
            tokenUserSells: WETH_ADDRESS,
            maxAmountUserSells: maxAmountUserSells
        });
    }

    function deployAndFundRFQSolver(SwapIntent memory swapIntent) internal returns (SimpleRFQSolverInvertBid) {
        vm.startPrank(solverOneEOA);
        SimpleRFQSolverInvertBid rfqSolver = new SimpleRFQSolverInvertBid(WETH_ADDRESS, address(atlas));
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1 ether);
        vm.stopPrank();

        deal(DAI_ADDRESS, address(rfqSolver), swapIntent.amountUserBuys);
        assertEq(DAI.balanceOf(address(rfqSolver)), swapIntent.amountUserBuys, "Did not give enough DAI to solver");

        return rfqSolver;
    }

    function createExecutionEnvironment(address control) internal returns (address){
        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(control);
        console.log("executionEnvironment", executionEnvironment);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        return executionEnvironment;
    }

    function buildUserOperation(address control, SwapIntent memory swapIntent) internal returns (UserOperation memory) {
        UserOperation memory userOp;

        bytes memory userOpData = abi.encodeCall(SwapIntentInvertBidDAppControl.swap, swapIntent);

        TxBuilder txBuilder = new TxBuilder({
            _control: control,
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: txBuilder.control(),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 2,
            data: userOpData
        });
        userOp.sessionKey = governanceEOA;

        return userOp;
    }

    function buildSolverOperation(address control, UserOperation memory userOp, SwapIntent memory swapIntent, address executionEnvironment,
        address solverAddress, uint256 solverBidAmount) internal returns (SolverOperation memory) {
        bytes memory solverOpData =
            abi.encodeCall(SimpleRFQSolverInvertBid.fulfillRFQ, (swapIntent, executionEnvironment, solverBidAmount));

        TxBuilder txBuilder = new TxBuilder({
            _control: control,
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        SolverOperation memory solverOp = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solverEOA: solverOneEOA,
            solverContract: solverAddress,
            bidAmount: solverBidAmount,
            value: 0
        });

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOp));
        solverOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        return solverOp;
    }

    function buildDAppOperation(address control, UserOperation memory userOp, SolverOperation[] memory solverOps) 
        internal returns (DAppOperation memory) {
        TxBuilder txBuilder = new TxBuilder({
            _control: control,
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });
        DAppOperation memory dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        return dAppOp;
    }

    function approveAtlasAndExecuteSwap(SwapIntent memory swapIntent, UserOperation memory userOp, SolverOperation[] memory solverOps, DAppOperation memory dAppOp) internal {
        vm.startPrank(userEOA);

        (bool simResult,,) = simulator.simUserOperation(userOp);
        assertFalse(simResult, "metasimUserOperationcall tested true a");

        WETH.approve(address(atlas), swapIntent.maxAmountUserSells);

        (simResult,,) = simulator.simUserOperation(userOp);
        assertTrue(simResult, "metasimUserOperationcall tested false c");
        uint256 gasLeftBefore = gasleft();

        vm.startPrank(userEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });

        console.log("Metacall Gas Cost:", gasLeftBefore - gasleft());
        vm.stopPrank();
    }
}

// This solver magically has the tokens needed to fulfil the user's swap.
// This might involve an offchain RFQ system
contract SimpleRFQSolverInvertBid is SolverBaseInvertBid {
    constructor(address weth, address atlas) SolverBaseInvertBid(weth, atlas, msg.sender, false) { }

    function fulfillRFQ(SwapIntent calldata swapIntent, address executionEnvironment, uint256 solverBidAmount) public {
        require(
            ERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= solverBidAmount,
            "Did not receive enough tokenUserSells (=solverBidAmount) to fulfill swapIntent"
        );
        require(
            ERC20(swapIntent.tokenUserBuys).balanceOf(address(this)) >= swapIntent.amountUserBuys,
            "Not enough tokenUserBuys to fulfill"
        );
        ERC20(swapIntent.tokenUserBuys).transfer(executionEnvironment, swapIntent.amountUserBuys);
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}
