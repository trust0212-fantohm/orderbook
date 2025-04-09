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
  const PRICE_DECIMALS = 6;

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