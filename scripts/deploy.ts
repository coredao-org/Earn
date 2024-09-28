import hre from "hardhat";

// verify STCore: npx hardhat verify  --network coredev 0x1122149F70D901D0196d40AA8FAD5b0b052499ff                        
// verify Earn alone: npx hardhat verify --network coredev --contract contracts/Earn.sol:Earn 0xD9Ee23223dCaEDc4025679D46F872c4800BBb8dB
// verify Proxy and Eean(proxy address), but proxy failed: npx hardhat verify 0x441073f2bAa9B531E80433c74427386CCC73C260  
async function main() {
  const [deployer] = await hre.ethers.getSigners();

  // Deploy STCore contract
  const STCore = await hre.ethers.deployContract("STCore");
  console.log("STCore Contract deployed to: ", STCore.target);

  // Deploy Earn contract
  const Earn = await hre.ethers.getContractFactory("Earn");
  const earn = await hre.upgrades.deployProxy(Earn, [STCore.target, deployer.address, deployer.address]);
  await earn.waitForDeployment();

  // Print Contract address
  console.log("Proxy Contract deployed to: ", earn.target)
  console.log("Implementation Contract deployed to:", await hre.upgrades.erc1967.getImplementationAddress(earn.target.toString()))

  // Set earn address to STCore
  const setEarnTx = await STCore.setEarnAddress(earn.target, {gasLimit: 4000000});
  const setEarnReceipt = await setEarnTx.wait();  
  console.log("Set STCore's earn address to: ", await STCore.earn());

  // Starting verify
  console.log("Starting verify........")

  await hre.run("verify:verify", {
    address: STCore.target,
    constructorArguments: [],
  });
  console.log("verify stcore success")

  await hre.run("verify:verify", {
    address: earn.target,
    constructorArguments: [],
  });
  console.log("verify earn success")
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});