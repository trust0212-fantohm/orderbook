import { expect } from "chai";
import { ethers } from "hardhat";
import { OrderBook, USDC, ACME } from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("OrderBook", function () {
  let orderBook: OrderBook;
  let usdc: USDC;
  let token: ACME;
  let trader1: SignerWithAddress;
  let trader2: SignerWithAddress;
  let buyer: SignerWithAddress;
  let seller: SignerWithAddress;
  let treasury: SignerWithAddress;

  const USDC_DECIMALS = 6;
  const TOKEN_DECIMALS = 18;

  beforeEach(async function () {
    [trader1, trader2, treasury, buyer, seller] = await ethers.getSigners();

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
    await usdc.connect(trader1).mint(ethers.utils.parseUnits("1000", USDC_DECIMALS));
    await usdc.connect(trader2).mint(ethers.utils.parseUnits("1000", USDC_DECIMALS));
    await usdc.connect(buyer).mint(ethers.utils.parseUnits("1000", USDC_DECIMALS));

    await token.connect(trader1).mint(ethers.utils.parseUnits("1000", TOKEN_DECIMALS));
    await token.connect(trader2).mint(ethers.utils.parseUnits("1000", TOKEN_DECIMALS));
    await token.connect(seller).mint(ethers.utils.parseUnits("1000", TOKEN_DECIMALS));
  });

  // describe("createBuyMarketOrder", function () {
  //   it("should execute buy market order successfully", async function () {
  //     // Create a sell limit order first
  //     const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
  //     const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
  //     const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

  //     await token.connect(trader1).approve(orderBook.address, tokenAmount);
  //     await orderBook.connect(trader1).createLimitOrder(
  //       price,
  //       tokenAmount,
  //       validTo,
  //       1, // OrderType.SELL
  //       {} // Transaction options
  //     );

  //     // Create buy market order
  //     const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
  //     await usdc.connect(trader2).approve(orderBook.address, usdcAmount);

  //     const trader2TokenBalanceBefore = await token.balanceOf(trader2.address);
  //     const trader2UsdcBalanceBefore = await usdc.balanceOf(trader2.address);

  //     await orderBook.connect(trader2).createBuyMarketOrder(usdcAmount);

  //     const trader2TokenBalanceAfter = await token.balanceOf(trader2.address);
  //     const trader2UsdcBalanceAfter = await usdc.balanceOf(trader2.address);

  //     expect(trader2TokenBalanceAfter).to.be.gt(trader2TokenBalanceBefore);
  //     expect(trader2UsdcBalanceAfter).to.be.lt(trader2UsdcBalanceBefore);
  //   });

  //   it("should distribute orders based on time when multiple orders exist at same price", async function () {
  //     // Create multiple sell limit orders at the same price
  //     const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
  //     const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
  //     const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

  //     // First order (oldest)
  //     await token.connect(trader1).approve(orderBook.address, tokenAmount);
  //     await orderBook.connect(trader1).createLimitOrder(
  //       price,
  //       tokenAmount,
  //       validTo,
  //       1
  //     );

  //     // Wait for 1 second to create time difference
  //     await new Promise(resolve => setTimeout(resolve, 1000));

  //     // Second order (middle)
  //     await token.connect(trader2).approve(orderBook.address, tokenAmount);
  //     await orderBook.connect(trader2).createLimitOrder(
  //       price,
  //       tokenAmount,
  //       validTo,
  //       1
  //     );

  //     // Wait for 1 second to create time difference
  //     await new Promise(resolve => setTimeout(resolve, 1000));

  //     // Third order (newest)
  //     await token.connect(trader1).approve(orderBook.address, tokenAmount);
  //     await orderBook.connect(trader1).createLimitOrder(
  //       price,
  //       tokenAmount,
  //       validTo,
  //       1
  //     );

  //     // Create a large buy market order that will match with all three sell orders
  //     const usdcAmount = ethers.utils.parseUnits("300", USDC_DECIMALS);
  //     await usdc.connect(trader2).approve(orderBook.address, usdcAmount);

  //     // Get initial balances
  //     const trader1InitialBalance = await usdc.balanceOf(trader1.address);
  //     const trader2InitialBalance = await usdc.balanceOf(trader2.address);

  //     // Execute buy market order
  //     await orderBook.connect(trader2).createBuyMarketOrder(usdcAmount);

  //     // Get final balances
  //     const trader1FinalBalance = await usdc.balanceOf(trader1.address);
  //     const trader2FinalBalance = await usdc.balanceOf(trader2.address);

  //     // Calculate received amounts
  //     const trader1Received = trader1FinalBalance.sub(trader1InitialBalance);
  //     const trader2Received = trader2FinalBalance.sub(trader2InitialBalance);

  //     // Since trader1 has two orders (oldest and newest) and trader2 has one (middle),
  //     // and the distribution is time-weighted, trader1 should receive more USDC than trader2
  //     expect(trader1Received).to.be.gt(trader2Received);
  //   });

  //   it("should revert if no active sell orders", async function () {
  //     const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
  //     await usdc.connect(trader1).approve(orderBook.address, usdcAmount);

  //     await expect(
  //       orderBook.connect(trader1).createBuyMarketOrder(usdcAmount)
  //     ).to.be.revertedWith("No active sell orders");
  //   });
  // });

  describe("createSellMarketOrder", function () {
    // it("should execute sell market order successfully", async function () {
    //   // Create a buy limit order first
    //   const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
    //   const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
    //   const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
    //   const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

    //   await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
    //   await orderBook.connect(trader1).createLimitOrder(
    //     price,
    //     tokenAmount,
    //     validTo,
    //     0 // OrderType.BUY  
    //   );

    //   // Create sell market order
    //   await token.connect(trader2).approve(orderBook.address, tokenAmount);

    //   const trader2UsdcBalanceBefore = await usdc.balanceOf(trader2.address);
    //   const trader2TokenBalanceBefore = await token.balanceOf(trader2.address);

    //   await orderBook.connect(trader2).createSellMarketOrder(tokenAmount);

    //   const trader2UsdcBalanceAfter = await usdc.balanceOf(trader2.address);
    //   const trader2TokenBalanceAfter = await token.balanceOf(trader2.address);

    //   expect(trader2UsdcBalanceAfter).to.be.gt(trader2UsdcBalanceBefore);
    //   expect(trader2TokenBalanceAfter).to.be.lt(trader2TokenBalanceBefore);
    // });

    it("should distribute sell market orders based on time when multiple buy orders exist at same price", async function () {
      // Create multiple buy limit orders at the same price
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      // First order (oldest)
      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        price,
        tokenAmount,
        validTo,
        0
      );

      // Wait for 1 second to create time difference
      await new Promise(resolve => setTimeout(resolve, 1000));

      // Second order (middle)
      await usdc.connect(trader2).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader2).createLimitOrder(
        price,
        tokenAmount,
        validTo,
        0
      );

      // Get initial balances
      const trader1InitialBalance = await token.balanceOf(trader1.address);
      const trader2InitialBalance = await token.balanceOf(trader2.address);

      // Execute sell market order
      await orderBook.connect(seller).createSellMarketOrder(tokenAmount);

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
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      // Calculate required USDC amount
      const usdcAmount = price.mul(tokenAmount).div(ethers.utils.parseUnits("1", USDC_DECIMALS));
      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);

      await orderBook.connect(trader1).createLimitOrder(
        price,
        tokenAmount,
        validTo,
        0 // OrderType.BUY
      );

      const order = await orderBook.orders(0);
      expect(order.trader).to.equal(trader1.address);
      expect(order.orderType).to.equal(0); // OrderType.BUY
      expect(order.desiredPrice).to.equal(price);
      expect(order.tokenAmount).to.equal(tokenAmount);
    });

    it("should distribute limit orders based on time when matching with multiple orders at same price", async function () {
      // Create multiple sell limit orders at the same price
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      // First sell order (oldest)
      await token.connect(trader1).approve(orderBook.address, tokenAmount);
      await orderBook.connect(trader1).createLimitOrder(
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
        price,
        usdcAmount,
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
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await token.connect(trader1).approve(orderBook.address, tokenAmount);

      await orderBook.connect(trader1).createLimitOrder(
        price,
        tokenAmount,
        validTo,
        1, // OrderType.SELL
        {} // Transaction options
      );

      const order = await orderBook.orders(0);
      expect(order.trader).to.equal(trader1.address);
      expect(order.orderType).to.equal(1); // OrderType.SELL
      expect(order.desiredPrice).to.equal(price);
      expect(order.tokenAmount).to.equal(tokenAmount);
    });

    it("should revert if validTo is in the past", async function () {
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) - 3600; // 1 hour ago

      await token.connect(trader1).approve(orderBook.address, tokenAmount);

      await expect(
        orderBook.connect(trader1).createLimitOrder(
          price,
          tokenAmount,
          validTo,
          1, // OrderType.SELL
          {} // Transaction options
        )
      ).to.be.revertedWith("Invalid time limit");
    });
  });

  describe("cancelOrder", function () {
    it("should cancel order successfully", async function () {
      // Create a limit order first
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        price,
        usdcAmount,
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
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        price,
        usdcAmount,
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
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        price,
        usdcAmount,
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
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
      await orderBook.connect(trader1).createLimitOrder(
        price,
        usdcAmount,
        validTo,
        0
      );

      await expect(
        orderBook.connect(trader2).cancelOrder(0)
      ).to.be.revertedWith("You are not an maker of this order");
    });
  });

  // describe("getLatestRate", function () {
  //   it("should return latest buy and sell orders", async function () {
  //     // Create a buy limit order
  //     const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
  //     const buyPrice = ethers.utils.parseUnits("1", USDC_DECIMALS);
  //     const validTo = Math.floor(Date.now() / 1000) + 3600;

  //     await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
  //     await orderBook.connect(trader1).createLimitOrder(
  //       buyPrice,
  //       usdcAmount,
  //       validTo,
  //       0 // OrderType.BUY
  //     );

  //     // Create a sell limit order
  //     const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
  //     const sellPrice = ethers.utils.parseUnits("1.1", USDC_DECIMALS);

  //     await token.connect(trader2).approve(orderBook.address, tokenAmount);
  //     await orderBook.connect(trader2).createLimitOrder(
  //       sellPrice,
  //       tokenAmount,
  //       validTo,
  //       1 // OrderType.SELL
  //     );

  //     const [latestBuyOrder, latestSellOrder] = await orderBook.getLatestRate();

  //     expect(latestBuyOrder.trader).to.equal(trader1.address);
  //     expect(latestBuyOrder.desiredPrice).to.equal(buyPrice);
  //     expect(latestBuyOrder.orderType).to.equal(0); // OrderType.BUY

  //     expect(latestSellOrder.trader).to.equal(trader2.address);
  //     expect(latestSellOrder.desiredPrice).to.equal(sellPrice);
  //     expect(latestSellOrder.orderType).to.equal(1); // OrderType.SELL
  //   });

  //   it("should return empty orders when no active orders exist", async function () {
  //     const [latestBuyOrder, latestSellOrder] = await orderBook.getLatestRate();

  //     expect(latestBuyOrder.trader).to.equal(ethers.constants.AddressZero);
  //     expect(latestBuyOrder.desiredPrice).to.equal(0);
  //     expect(latestBuyOrder.orderType).to.equal(0);

  //     expect(latestSellOrder.trader).to.equal(ethers.constants.AddressZero);
  //     expect(latestSellOrder.desiredPrice).to.equal(0);
  //     expect(latestSellOrder.orderType).to.equal(0);
  //   });
  // });

  describe("getOrderBook", function () {
    it("should return buy orders in ascending price order", async function () {
      // Create multiple buy orders with different prices
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      // Create buy orders with prices: 1.0, 1.1, 1.2
      const prices = [
        ethers.utils.parseUnits("1.0", USDC_DECIMALS),
        ethers.utils.parseUnits("1.1", USDC_DECIMALS),
        ethers.utils.parseUnits("1.2", USDC_DECIMALS)
      ];

      for (const price of prices) {
        await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
        await orderBook.connect(trader1).createLimitOrder(
          price,
          usdcAmount,
          validTo,
          0 // OrderType.BUY
        );
      }

      const buyOrders = await orderBook.getOrderBook(3, 0); // 0 = OrderType.BUY

      expect(buyOrders.length).to.equal(3);
      expect(buyOrders[0].desiredPrice).to.equal(prices[0]); // Lowest price first
      expect(buyOrders[1].desiredPrice).to.equal(prices[1]);
      expect(buyOrders[2].desiredPrice).to.equal(prices[2]); // Highest price last
    });

    it("should return sell orders in descending price order", async function () {
      // Create multiple sell orders with different prices
      const tokenAmount = ethers.utils.parseUnits("100", TOKEN_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      // Create sell orders with prices: 1.2, 1.1, 1.0
      const prices = [
        ethers.utils.parseUnits("1.2", USDC_DECIMALS),
        ethers.utils.parseUnits("1.1", USDC_DECIMALS),
        ethers.utils.parseUnits("1.0", USDC_DECIMALS)
      ];

      for (const price of prices) {
        await token.connect(trader1).approve(orderBook.address, tokenAmount);
        await orderBook.connect(trader1).createLimitOrder(
          price,
          tokenAmount,
          validTo,
          1 // OrderType.SELL
        );
      }

      const sellOrders = await orderBook.getOrderBook(3, 1); // 1 = OrderType.SELL

      expect(sellOrders.length).to.equal(3);
      expect(sellOrders[0].desiredPrice).to.equal(prices[2]); // Lowest price first (1.0)
      expect(sellOrders[1].desiredPrice).to.equal(prices[1]); // Middle price (1.1)
      expect(sellOrders[2].desiredPrice).to.equal(prices[0]); // Highest price last (1.2)
    });

    it("should return limited number of orders when depth is specified", async function () {
      // Create multiple buy orders
      const usdcAmount = ethers.utils.parseUnits("100", USDC_DECIMALS);
      const price = ethers.utils.parseUnits("1", USDC_DECIMALS);
      const validTo = Math.floor(Date.now() / 1000) + 3600;

      // Create 5 buy orders
      for (let i = 0; i < 5; i++) {
        await usdc.connect(trader1).approve(orderBook.address, usdcAmount);
        await orderBook.connect(trader1).createLimitOrder(
          price,
          usdcAmount,
          validTo,
          0 // OrderType.BUY
        );
      }

      // Request only 2 orders
      const buyOrders = await orderBook.getOrderBook(2, 0); // 0 = OrderType.BUY

      expect(buyOrders.length).to.equal(2);
    });

    it("should return empty array when no orders exist", async function () {
      const buyOrders = await orderBook.getOrderBook(3, 0); // 0 = OrderType.BUY
      const sellOrders = await orderBook.getOrderBook(3, 1); // 1 = OrderType.SELL

      expect(buyOrders.length).to.equal(0);
      expect(sellOrders.length).to.equal(0);
    });
  });
});