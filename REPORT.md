# Notional's AMM is vulnerable to price manipulation using flash loans

## Bug Description

I've discovered a vulnerability in the Notional Finance contracts whereby an attacker can drain both cUSDC and cDAI from the Notional proxy contract at address 0x1344A36A1B56144C3Bc62E7757377D288fDE0369.

An attacker is able to call the following three functions and withdraw more than they deposited:

1. `batchBalanceAction` with an action type of `DepositActionType.DepositUnderlyingAndMintNToken`
2. `nTokenRedeem` on all minted nTokens with parameters `sellTokenAssets == true` and `acceptResidualAssets == true`
3. `withdraw` on the entire cash balance

The attack appears to depend on the configuration and current state of the DAI and USDC liquidity pools. However, the attack can be carried out right now (in early September 2022).

I have provided an executable Proof of Concept implemented using [Foundry](https://book.getfoundry.sh/) that demonstrates an attack at block height 15456374 that causes approximately $1.49M of economic damage to Notional.

## Impact

The impact is that cDAI and cUSDC are drained from the Notional Proxy contract at address 0x1344A36A1B56144C3Bc62E7757377D288fDE0369.

## Proof of Concept

An executable proof of concept, implemented in Foundry, has been attached to this vulnerablity report. Simply untar/gzip it and follow the instructions in the README.MD.

The attack uses an Aave flashloan to borrow $188M DAI and $250M USDC and perform the attack.

It results in approximately $1.49M of economic damage and a substantial profit for the attacker.

### Economic damage could be much higher

The underlying mathematical model of Notional is somewhat complex. I estimate that a full analysis of the AMM would take me a few weeks. The attached Proof of Concept was constructed in an experimental fashion based on the suspicion that a large enough injection of capital could cause the underlying price of nTokens to change enough to cause a favourable result for the attacker. This suspicision turned out to be correct.

However, I believe that once a full analysis of the underlying mathematical model is done the potential economic damage could be a lot higher than the $1.49M I have demonstrated.

It is clear that the severity of this exploit means that it should be disclosed as soon as possible, even before a more thorough analysis is done.

I am engaged in auditing work for the coming 3 weeks, starting September 5, but would be very open to continuing the analysis of the underlying issue with Notional if that is something you would be open to.

## Sensitivity to amounts and price manipulation

The protections the AMM provides to lower the impact of price manipulation do seem to work to some degree.

I found that smaller deposits led to a great percentage profit, but not a greater absolute profit for the attacker.

Also, price manipulation is clearly a part of the underlying cause. In the attached executable PoC we:
- repeat the attack
- but before we deposit and mint nTokens, we use Notional's `borrow` function to manipulate the price in various market indexes.

This results in a modest increase in the economic damage but proves that price manipulation is the underlying cause.

Also, the attack can be carried out on the DAI and USDC pools but, curiously, does not work on the WBTC pool. A cursory analysis shows that this pool does not have 1 year fCash, only 3 month and 6 month fCash.

## Risk Breakdown
Difficulty to Exploit: Easy
Weakness: Mathematical flaws in AMM or misconfigured market parameters
CVSS2 Score: Critical

## Recommendation

I recommend a deeper exploration of Notional's AMM for vulnerabilities.

When interacting with the public contracts it is difficult to get visiblity on the internal data structures. This could be remedied by using the Brownie testing framework, instead of Foundry,  but that would mean populating all the tests with the correct data which could take days/weeks to construct. The exploit that was discovered works on the state of the contracts as they currently are.

--------

## Proof of Concept

The proof of concept has been uploaded to [anonyfile.com](https://anonymfile.com) as encrypted files since there seems to only be scope to upload PNGs and JPEGs to Immunefi.

There are two versions of the archive:
1. `eb6ceeb21ac4cee023f4de21c33d7c2a28666f06.tgz.crypt`. This has been encrypted using Linux's `crypt` command and can be decrypted with:

   ```
   $ cat eb6ceeb21ac4cee023f4de21c33d7c2a28666f06.tgz.crypt | crypt > poc.tgz
   ```

2. A Mac OS X AES-256 encrypted `.dmg` file which contains the unencrypted `eb6ceeb21ac4cee023f4de21c33d7c2a28666f06.tgz`

The link to the file encrypted with `crypt` is: https://anonymfile.com/YdoY/eb6ceeb21ac4cee023f4de21c33d7c2a28666f06tgz.crypt
The link to the file in an AES-256 Mac OS X .dmg file is: https://anonymfile.com/lyl9/eb6ceeb21ac4cee023f4de21c33d7c2a28666f06.dmg
The password for both is:

Once decrypted, unzipped and untarred please follow the instructions in README.md

When examining the code please feel free to use the logging functions I have written.
In particular commenting out calls to `logAll` within function `performAttack` will yield verbose, but useful, output.

If you have any difficulty please email me at one.hundred.proof@proton.me