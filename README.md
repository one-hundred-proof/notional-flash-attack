# A Proof of Concept for a hypothetical attack on Notional Finance's smart contracts

**The vector that allowed this attack has now been fixed on the Ethereum mainnet**

## Introduction

This is the Proof of Concept that I submitted to [Notional Finance](https://notional.finance) via [Immunefi](https://immunefi.com), a bug bounty platform.

It runs a Foundry test at a particular block height to show that a small bug in the `AccountAction.nTokenRedeem` function allowed an attacker -- with the help of a flash loan from Aave -- to drain the contract of approximately $1.49M of value.

Notional Finance's post-mortem can be found [here](https://blog.notional.finance/ntoken-redemption-bug-post-mortem/).

# How to run this Proof of Concept

## Setup

```
$ npm install
```

If you have installed Foundry yet, install it with:

```
$ curl -L https://foundry.paradigm.xyz | bash
```

I ran this PoC locally with the following `forge` version:

```
$ forge --version
forge 0.2.0 (e947899 2022-09-02T00:06:30.659378189Z)
```

## Running the Proof of Concept

```
$ ./run-forge
```
