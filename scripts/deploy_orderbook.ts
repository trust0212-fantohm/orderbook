import { ethers, upgrades } from "hardhat";

async function main() {
  const OrderBook = await ethers.getContractFactory("OrderBook");
  const orderBook = await upgrades.deployProxy(
    OrderBook,
    ["0x243084Abef0685D40D3BAE3545eDF0bF35E4Eb1f", "treasury", "oracle"],
    {
      initializer: "initialize",
    }
  );
  await orderBook.waitForDeployment();
  console.log("orderBook address", await orderBook.getAddress());
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
