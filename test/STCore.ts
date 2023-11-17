import { expect } from "chai";
import hre from "hardhat";

describe("STCore contract sample test", function () {
  it("Deployment should assign the total supply of tokens to the owner", async function () {
    const [owner] = await hre.ethers.getSigners();

    const hardhatToken = await hre.ethers.deployContract("STCore");

    const ownerBalance = await hardhatToken.balanceOf(owner.address);
    expect(await hardhatToken.totalSupply()).to.equal(ownerBalance);
  });
});