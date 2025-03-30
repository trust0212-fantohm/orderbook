import { BigNumber } from "ethers";
import { ethers } from "hardhat";

export enum OrderType {
  BUY,
  SELL
}

export const getBlockTimeStamp = async () => {
  const block = await ethers.provider.getBlock("latest");

  if (!block) return BigNumber.from("0");
  const blockTimeStamp = BigNumber.from(block?.timestamp + 30000);
  console.log("blockTimeStamp", blockTimeStamp);
  
  return blockTimeStamp;
};
