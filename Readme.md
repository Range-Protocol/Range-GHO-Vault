# Range Protocol's GHO Vault

# Overview

Range Protocol is a Uniswap V2-like interface which enables providing fungible liquidity to Uniswap V3 for arbitrary liquidity provision: one-sided, lop-sided, and balanced.
The GHO vault from Range Protocol has slightly different and additional behaviour of accepting a liquidity in collateral token and borrowing GHO against depositing
a specific percentage of collateral on Aave. GHO vaults will be used to peg GHO against the asset with which the GHO is paired in the vault. The manager of the vault will
perform the actions associated with the pegging.
