import { parseUnits } from "ethers/lib/utils";
import { ethers, upgrades } from "hardhat";

export async function basicFixture() {
    const [owner, treasury, user1, user2, user3, sellTrader, buyTrader] = await ethers.getSigners();

    // deploy usdc token
    const usdcFactory = await ethers.getContractFactory("USDC");
    const usdc = await usdcFactory.deploy();
    await usdc.deployed();

    // deploy test token
    const tokenFactory = await ethers.getContractFactory("ACME");
    const token = await tokenFactory.deploy();
    await token.deployed();

    // deploy test oracle
    const oracleFactory = await ethers.getContractFactory("Oracle");
    const oracle = await oracleFactory.deploy("ACME-USD");
    await oracle.deployed();

    const OrderBookFactory = await ethers.getContractFactory("OrderBook");
    const orderBook = await upgrades.deployProxy(
        OrderBookFactory,
        [
            usdc.address,
            token.address,
            treasury.address,
            oracle.address
        ],
        {
            initializer: "initialize",
        }
    );
    await orderBook.deployed();

    // write first price on oracle
    await oracle.writePrice(parseUnits("0.01", 6));

    // mint and approve usdc
    await usdc.mint(parseUnits("1000", 6));
    await usdc.connect(user1).mint(parseUnits("1000", 6));
    await usdc.connect(user2).mint(parseUnits("1000", 6));
    await usdc.connect(user3).mint(parseUnits("1000", 6));
    await usdc.connect(buyTrader).mint(parseUnits("1000", 6));

    await usdc.approve(orderBook.address, parseUnits("1000", 6));
    await usdc.connect(user1).approve(orderBook.address, parseUnits("1000", 6));
    await usdc.connect(user2).approve(orderBook.address, parseUnits("1000", 6));
    await usdc.connect(user3).approve(orderBook.address, parseUnits("1000", 6));
    await usdc.connect(buyTrader).approve(orderBook.address, parseUnits("1000", 6));

    // mint and approve tokens
    await token.mint(parseUnits("1000", 6));
    await token.connect(user1).mint(parseUnits("1000", 18));
    await token.connect(user2).mint(parseUnits("1000", 18));
    await token.connect(user3).mint(parseUnits("1000", 18));
    await token.connect(sellTrader).mint(parseUnits("1000", 18));

    await token.approve(orderBook.address, parseUnits("1000", 18));
    await token.connect(user1).approve(orderBook.address, parseUnits("1000", 18));
    await token.connect(user2).approve(orderBook.address, parseUnits("1000", 18));
    await token.connect(user3).approve(orderBook.address, parseUnits("1000", 18));
    await token.connect(sellTrader).approve(orderBook.address, parseUnits("1000", 18));

    return { orderBook, oracle, usdc, token, owner, treasury, user1, user2, user3, sellTrader, buyTrader };
}