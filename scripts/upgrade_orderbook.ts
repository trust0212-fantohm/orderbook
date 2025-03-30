import { ethers, upgrades } from "hardhat";

async function main() {
  const OrderBook =
    await ethers.getContractFactory("OrderBook");
  const orderBook = await upgrades.upgradeProxy("", OrderBook);
  console.log("OrderBook Upgraded", await orderBook.getAddress());
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
