import { ethers, upgrades } from "hardhat";

export async function basicFixture() {
    const [owner, treasury, user1, user2, user3, sellTrader, buyTrader] = await ethers.getSigners();
    
    // deploy test token
    const tokenFactory = await ethers.getContractFactory("ACME");
    const token = await tokenFactory.deploy();
    await token.deployed();

    // deploy test oracle
    const oracleFactory = await ethers.getContractFactory("Oracle");
    const oracle = await oracleFactory.deploy("MATIC-USD", 9);
    await oracle.deployed();

    const OrderBookFactory = await ethers.getContractFactory("OrderBook");
    const orderBook = await upgrades.deployProxy(
        OrderBookFactory,
        [
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
    await oracle.writePrice(ethers.utils.parseUnits("0.54", 9));

    // mint and approve tokens
    await token.mint(ethers.utils.parseEther("10000"));
    await token.connect(user1).mint(ethers.utils.parseEther("10000"));
    await token.connect(user2).mint(ethers.utils.parseEther("10000"));
    await token.connect(user3).mint(ethers.utils.parseEther("10000"));
    await token.connect(sellTrader).mint(ethers.utils.parseEther("10000"));

    await token.approve(orderBook.address, ethers.utils.parseEther("10000"));
    await token.connect(user1).approve(orderBook.address, ethers.utils.parseEther("10000"));
    await token.connect(user2).approve(orderBook.address, ethers.utils.parseEther("10000"));
    await token.connect(user3).approve(orderBook.address, ethers.utils.parseEther("10000"));
    await token.connect(sellTrader).approve(orderBook.address, ethers.utils.parseEther("10000"));

    return {orderBook, oracle, token, owner, treasury, user1, user2, user3, sellTrader, buyTrader};
}