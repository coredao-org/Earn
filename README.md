# Install dependencies steps

1. Install node on MacOS, if other operating system refer to https://hardhat.org/tutorial/setting-up-the-environment.

   ```shell
   curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash
   nvm install 20
   nvm use 20
   nvm alias default 20
   npm install npm --global # Upgrade npm to the latest version
   ```

2. Install dependencies

   ```shell
   npm install
   ```

# Deply contracts

1. Deploy STCore.sol
1. Deploy Earn.sol using STCore's address
1. Call STCore's `setEarnAddress(address _earn)` using Earn's address
1. Call Earn's `updateOperator(address _operator)`
1. Call Earn's `updateProtocolFeeReveiver(address _protocolFeeReceiver)`

