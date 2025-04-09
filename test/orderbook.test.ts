import { expect } from "chai";
import { ethers } from "hardhat";
import { OrderBook, USDC, ACME } from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("OrderBook", function () {
  let orderBook: OrderBook;
  let usdc: USDC;
  let token: ACME;
  let owner: SignerWithAddress;
  let trader1: SignerWithAddress;
  let trader2: SignerWithAddress;
  let treasury: SignerWithAddress;

  const USDC_DECIMALS = 6;
  const TOKEN_DECIMALS = 18;
  const PRICE_DECIMALS = 18;

  beforeEach(async function () {
    [owner, trader1, trader2, treasury] = await ethers.getSigners();

    // Deploy USDC
    const USDC = await ethers.getContractFactory("USDC");
    usdc = await USDC.deploy();
    await usdc.deployed();

    // Deploy Token
    const Token = await ethers.getContractFactory("ACME");
    token = await Token.deploy();
    await token.deployed();

    // Deploy OrderBook
    const OrderBook = await ethers.getContractFactory("OrderBook");
    orderBook = await OrderBook.deploy();
    await orderBook.deployed();

    // Initialize OrderBook
    await orderBook.initialize(usdc.address, token.address, treasury.address);

    // Mint tokens to traders
    await usdc.mint(ethers.utils.parseUnits("1000000", USDC_DECIMALS));
    await token.mint(ethers.utils.parseUnits("1000000", TOKEN_DECIMALS));

    // Transfer tokens to traders
    await usdc.transfer(trader1.address, ethers.utils.parseUnits("100000", USDC_DECIMALS));
    await usdc.transfer(trader2.address, ethers.utils.parseUnits("100000", USDC_DECIMALS));
    await token.transfer(trader1.address, ethers.utils.parseUnits("100000", TOKEN_DECIMALS));
    await token.transfer(trader2.address, ethers.utils.parseUnits("100000", TOKEN_DECIMALS));
  });

  describe("createBuyMarketOrder", function () {
    it("should execute buy market order successfully", async function () {
      // Create a sell limit order first
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader1).createLimitOrder(
        0, // usdcAmount
        price,
        tokenAmount,
        validTo,
        1 // OrderType.SELL
      );

      // Create buy market order
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      await usdc.connect(trader2).approve(orderBook.address, usdcAmount);
      
      const trader2TokenBalanceBefore = await token.balanceOf(trader2.address);
      const trader2UsdcBalanceBefore = await usdc.balanceOf(trader2.address);
      
      await orderBook.connect(trader2).createBuyMarketOrder(usdcAmount);

      const trader2TokenBalanceAfter = await token.balanceOf(trader2.address);
      const trader2UsdcBalanceAfter = await usdc.balanceOf(trader2.address);

      expect(trader2TokenBalanceAfter).to.be.gt(trader2TokenBalanceBefore);
      expect(trader2UsdcBalanceAfter).to.be.lt(trader2UsdcBalanceBefore);
    });

    it("should distribute orders based on time when multiple orders exist at same price", async function () {
      // Create multiple sell limit orders at the same price
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      // First order (oldest)
      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader1).createLimitOrder(
        0,
        price,
        tokenAmount,
        validTo,
        1
      );

      // Wait for 1 second to create time difference
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Second order (middle)
      await token.connect(trader2).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader2).createLimitOrder(
        0,
        price,
        tokenAmount,
        validTo,
        1
      );

      // Wait for 1 second to create time difference
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Third order (newest)
      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader1).createLimitOrder(
        0,
        price,
        tokenAmount,
        validTo,
        1
      );

      // Create a large buy market order that will match with all three sell orders
      const usdcAmount = ethers.utils.parseUnits("300", USDC_DECIMALS);
      await usdc.connect(trader2).approve(orderBook.address, usdcAmount);

      // Get initial balances
      const trader1InitialBalance = await usdc.balanceOf(trader1.address);
      const trader2InitialBalance = await usdc.balanceOf(trader2.address);

      // Execute buy market order
      await orderBook.connect(trader2).createBuyMarketOrder(usdcAmount);

      // Get final balances
      const trader1FinalBalance = await usdc.balanceOf(trader1.address);
      const trader2FinalBalance = await usdc.balanceOf(trader2.address);

      // Calculate received amounts
      const trader1Received = trader1FinalBalance.sub(trader1InitialBalance);
      const trader2Received = trader2FinalBalance.sub(trader2InitialBalance);

      // Since trader1 has two orders (oldest and newest) and trader2 has one (middle),
      // and the distribution is time-weighted, trader1 should receive more USDC than trader2
      expect(trader1Received).to.be.gt(trader2Received);
    });

    it("should revert if no active sell orders", async function () {
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      
      await expect(
        orderBook.connect(trader1).createBuyMarketOrder(usdcAmount)
      ).to.be.revertedWith("No active sell orders");
    });
  });

  describe("createSellMarketOrder", function () {
    it("should execute sell market order successfully", async function () {
      // Create a buy limit order first
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0, // tokenAmount
        validTo,
        0 // OrderType.BUY
      );

      // Create sell market order
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      await token.connect(trader2).approve(orderBook.address, tokenAmount);
      
      const trader2UsdcBalanceBefore = await usdc.balanceOf(trader2.address);
      const trader2TokenBalanceBefore = await token.balanceOf(trader2.address);
      
      await orderBook.connect(trader2).createSellMarketOrder(tokenAmount);

      const trader2UsdcBalanceAfter = await usdc.balanceOf(trader2.address);
      const trader2TokenBalanceAfter = await token.balanceOf(trader2.address);

      expect(trader2UsdcBalanceAfter).to.be.gt(trader2UsdcBalanceBefore);
      expect(trader2TokenBalanceAfter).to.be.lt(trader2TokenBalanceBefore);
    });

    it("should distribute sell market orders based on time when multiple buy orders exist at same price", async function () {
      // Create multiple buy limit orders at the same price
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      // First order (oldest)
      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0,
        validTo,
        0
      );

      // Wait for 1 second to create time difference
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Second order (middle)
      await usdc.connect(trader2).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader2).createLimitOrder(
        usdcAmount,
        price,
        0,
        validTo,
        0
      );

      // Wait for 1 second to create time difference
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Third order (newest)
      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0,
        validTo,
        0
      );

      // Create a large sell market order that will match with all three buy orders
      const tokenAmount = ethers.utils.parseUnits("300", TOKEN_DECIMALS);
      await token.connect(trader2).approve(orderBook.address, tokenAmount);

      // Get initial balances
      const trader1InitialBalance = await token.balanceOf(trader1.address);
      const trader2InitialBalance = await token.balanceOf(trader2.address);

      // Execute sell market order
      await orderBook.connect(trader2).createSellMarketOrder(tokenAmount);

      // Get final balances
      const trader1FinalBalance = await token.balanceOf(trader1.address);
      const trader2FinalBalance = await token.balanceOf(trader2.address);

      // Calculate received amounts
      const trader1Received = trader1FinalBalance.sub(trader1InitialBalance);
      const trader2Received = trader2FinalBalance.sub(trader2InitialBalance);

      // Since trader1 has two orders (oldest and newest) and trader2 has one (middle),
      // and the distribution is time-weighted, trader1 should receive more tokens than trader2
      expect(trader1Received).to.be.gt(trader2Received);
    });

    it("should revert if no active buy orders", async function () {
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      
      await expect(
        orderBook.connect(trader1).createSellMarketOrder(tokenAmount)
      ).to.be.revertedWith("No active buy orders");
    });
  });

  describe("createLimitOrder", function () {
    it("should create buy limit order successfully", async function () {
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0, // tokenAmount
        validTo,
        0 // OrderType.BUY
      );

      const order = await orderBook.orders(0);
      expect(order.trader).to.equal(trader1.address);
      expect(order.orderType).to.equal(0); // OrderType.BUY
      expect(order.desiredPrice).to.equal(price);
      expect(order.usdcAmount).to.equal(usdcAmount);
    });

    it("should distribute limit orders based on time when matching with multiple orders at same price", async function () {
      // Create multiple sell limit orders at the same price
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      // First sell order (oldest)
      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader1).createLimitOrder(
        0,
        price,
        tokenAmount,
        validTo,
        1
      );

      // Wait for 1 second to create time difference
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Second sell order (middle)
      await token.connect(trader2).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader2).createLimitOrder(
        0,
        price,
        tokenAmount,
        validTo,
        1
      );

      // Wait for 1 second to create time difference
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Third sell order (newest)
      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader1).createLimitOrder(
        0,
        price,
        tokenAmount,
        validTo,
        1
      );

      // Create a large buy limit order that will match with all three sell orders
      const usdcAmount = ethers.utils.parseUnits("300", USDC_DECIMALS);
      await usdc.connect(trader2).approve(orderBook.address, usdcAmount);

      // Get initial balances
      const trader1InitialBalance = await usdc.balanceOf(trader1.address);
      const trader2InitialBalance = await usdc.balanceOf(trader2.address);

      // Execute buy limit order
      await orderBook.connect(trader2).createLimitOrder(
        usdcAmount,
        price,
        0,
        validTo,
        0
      );

      // Get final balances
      const trader1FinalBalance = await usdc.balanceOf(trader1.address);
      const trader2FinalBalance = await usdc.balanceOf(trader2.address);

      // Calculate received amounts
      const trader1Received = trader1FinalBalance.sub(trader1InitialBalance);
      const trader2Received = trader2FinalBalance.sub(trader2InitialBalance);

      // Since trader1 has two sell orders (oldest and newest) and trader2 has one (middle),
      // and the distribution is time-weighted, trader1 should receive more USDC than trader2
      expect(trader1Received).to.be.gt(trader2Received);
    });

    it("should create sell limit order successfully", async function () {
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      
      await orderBook.connect(trader1).createLimitOrder(
        0, // usdcAmount
        price,
        tokenAmount,
        validTo,
        1 // OrderType.SELL
      );

      const order = await orderBook.orders(0);
      expect(order.trader).to.equal(trader1.address);
      expect(order.orderType).to.equal(1); // OrderType.SELL
      expect(order.desiredPrice).to.equal(price);
      expect(order.tokenAmount).to.equal(tokenAmount);
    });

    it("should revert if validTo is in the past", async function () {
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) - 3600; // 1 hour ago

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      
      await expect(
        orderBook.connect(trader1).createLimitOrder(
          usdcAmount,
          price,
          0, // tokenAmount
          validTo,
          0 // OrderType.BUY
        )
      ).to.be.revertedWith("Invalid time limit");
    });
  });

  describe("cancelOrder", function () {
    it("should cancel order successfully", async function () {
      // Create a limit order first
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0, // tokenAmount
        validTo,
        0 // OrderType.BUY
      );

      const trader1UsdcBalanceBefore = await usdc.balanceOf(trader1.address);
      
      await orderBook.connect(trader1).cancelOrder(0);

      const trader1UsdcBalanceAfter = await usdc.balanceOf(trader1.address);
      const order = await orderBook.orders(0);

      expect(trader1UsdcBalanceAfter).to.be.gt(trader1UsdcBalanceBefore);
      expect(order.isCanceled).to.be.true;
    });

    it("should revert if order is already canceled", async function () {
      // Create and cancel an order
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0,
        validTo,
        0
      );
      await orderBook.connect(trader1).cancelOrder(0);

      await expect(
        orderBook.connect(trader1).cancelOrder(0)
      ).to.be.revertedWith("Already canceled");
    });

    it("should revert if order is already filled", async function () {
      // Create a limit order and fill it
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0,
        validTo,
        0
      );

      // Create a matching sell market order to fill the buy order
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      await token.connect(trader2).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader2).createSellMarketOrder(tokenAmount);

      await expect(
        orderBook.connect(trader1).cancelOrder(0)
      ).to.be.revertedWith("Order already filled");
    });

    it("should revert if caller is not the order maker", async function () {
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", PRICE_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        usdcAmount,
        price,
        0,
        validTo,
        0
      );

      await expect(
        orderBook.connect(trader2).cancelOrder(0)
      ).to.be.revertedWith("You are not an maker of this order");
    });
  });
});