import { loadFixture } from "ethereum-waffle"
import { basicFixture } from "./fixture"
import { expect } from "chai";
import { ethers } from "hardhat";
import { OrderType } from "./utils/help";
import { parseUnits } from "ethers/lib/utils";

describe("Order book test", () => {
  describe("Create Market Order without limit order", () => {
    it("Should be failed to create market order without limit order", async () => {
      const { orderBook, buyTrader, sellTrader } = await loadFixture(basicFixture);

      // buy order
      await expect(orderBook.connect(buyTrader).createBuyMarketOrder(parseUnits("100", 6))).to.be.revertedWith("No active sell orders");

      // sell order
      await expect(orderBook.connect(sellTrader).createSellMarketOrder(parseUnits("1000", 18))).to.be.revertedWith("No active buy orders");
    });
  });

  describe("Time-based weighted distribution", () => {
    it("should distribute tokens based on order age when selling tokens", async () => {
      const { orderBook, usdc, token, user1, user2, sellTrader } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      // user1 places older buy order
      await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.BUY,
      );

      // Wait 5 seconds
      await ethers.provider.send("evm_increaseTime", [5]);
      await ethers.provider.send("evm_mine", []);

      // user2 places newer buy order
      await orderBook.connect(user2).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.BUY,
      );

      const before1 = await token.balanceOf(user1.address);
      const before2 = await token.balanceOf(user2.address);

      // sellTrader executes market sell for 150 tokens
      await expect(orderBook.connect(sellTrader).createSellMarketOrder(parseUnits("250", 18))).to.be.revertedWith("Insufficient USDC supply");
      await orderBook.connect(sellTrader).createSellMarketOrder(parseUnits("150", 18));

      const after1 = await token.balanceOf(user1.address);
      const after2 = await token.balanceOf(user2.address);

      const user1Received = after1.sub(before1);
      const user2Received = after2.sub(before2);

      // user1's older order should get more tokens than user2
      expect(user1Received).to.be.gt(user2Received);
    });

    it("should distribute USDC based on order age when buying tokens", async () => {
      const { orderBook, usdc, user1, user2, buyTrader } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      // Older sell order by user1
      await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.SELL
      );

      await ethers.provider.send("evm_increaseTime", [5]);
      await ethers.provider.send("evm_mine", []);

      // Newer sell order by user2
      await orderBook.connect(user2).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.SELL
      );

      const before1 = await usdc.balanceOf(user1.address);
      const before2 = await usdc.balanceOf(user2.address);

      await expect(orderBook.connect(buyTrader).createBuyMarketOrder(parseUnits("2.5", 6))).to.be.revertedWith("Insufficient Token Supply");
      await orderBook.connect(buyTrader).createBuyMarketOrder(parseUnits("1.5", 6));

      const after1 = await usdc.balanceOf(user1.address);
      const after2 = await usdc.balanceOf(user2.address);

      const received1 = after1.sub(before1);
      const received2 = after2.sub(before2);

      // user1's older order should get more USDC than user2
      expect(received1).to.be.gt(received2);
    });
  });

  describe("OrderBook - createLimitOrder function", () => {
    it("should create and store a buy limit order when no matching sell order exists", async () => {
      const { orderBook, user1 } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      const tx = await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.01", 6), // price
        parseUnits("100", 18), // amount
        block.timestamp + 3600,
        OrderType.BUY
      );
      await tx.wait();

      // Get the order ID from the event
      const orderId = (await orderBook.activeOrderIds(OrderType.BUY, 0)).toNumber();
      const order = await orderBook.orders(orderId);
      
      expect(order.desiredPrice.toString()).to.equal(parseUnits("0.01", 6).toString());
      expect(order.trader).to.equal(user1.address);
    });

    it("should create and store a sell limit order when no matching buy order exists", async () => {
      const { orderBook, user1 } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      const tx = await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.02", 6), // price
        parseUnits("50", 18), // amount
        block.timestamp + 3600,
        OrderType.SELL
      );
      await tx.wait();

      // Get the order ID from the event
      const orderId = (await orderBook.activeOrderIds(OrderType.SELL, 0)).toNumber();
      const order = await orderBook.orders(orderId);
      
      expect(order.desiredPrice.toString()).to.equal(parseUnits("0.02", 6).toString());
      expect(order.trader).to.equal(user1.address);
    });

    it("should partially fill a buy limit order if matching sell order exists at lower price", async () => {
      const { orderBook, user1, user2 } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      // user1 places a sell order
      await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("50", 18),
        block.timestamp + 3600,
        OrderType.SELL
      );

      // user2 places a buy order with more quantity
      await orderBook.connect(user2).createLimitOrder(
        parseUnits("0.02", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.BUY
      );

      // Get the order ID from the event
      const orderId = (await orderBook.activeOrderIds(OrderType.BUY, 0)).toNumber();
      const order = await orderBook.orders(orderId);
      
      // Order should be partially filled
      expect(order.remainTokenAmount).to.be.lt(parseUnits("100", 18));
      expect(order.remainTokenAmount).to.be.gt(0);
    });

    it("should fail if timeInForce is in the past", async () => {
      const { orderBook, user1 } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      await expect(
        orderBook.connect(user1).createLimitOrder(
          parseUnits("0.01", 6),
          parseUnits("100", 18),
          block.timestamp - 1,
          OrderType.BUY
        )
      ).to.be.revertedWith("Invalid time limit");
    });

    it("should match sell limit order with highest buy order respecting time-weight", async () => {
      const { orderBook, user1, user2, user3 } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      // user1 places a buy order
      await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.BUY
      );

      // wait
      await ethers.provider.send("evm_increaseTime", [5]);
      await ethers.provider.send("evm_mine", []);

      // user2 places a second buy order at the same price
      await orderBook.connect(user2).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.BUY
      );

      const before1 = await ethers.provider.getBalance(user1.address);
      const before2 = await ethers.provider.getBalance(user2.address);

      // user3 sells tokens
      await orderBook.connect(user3).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("150", 18),
        block.timestamp + 3600,
        OrderType.SELL
      );

      // Get the order ID from the event
      const orderId = (await orderBook.activeOrderIds(OrderType.SELL, 0)).toNumber();
      const order = await orderBook.orders(orderId);
      
      // Order should be filled
      expect(order.isFilled).to.be.true;
    });
  });

  describe("OrderBook - Fee and Treasury functionality", () => {
    it("should collect fees on buy market orders", async () => {
      const { orderBook, usdc, token, user1, treasury } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      // Create a sell order
      await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.SELL
      );

      const beforeTreasury = await token.balanceOf(treasury.address);
      const beforeUser = await token.balanceOf(user1.address);

      // Execute buy market order
      await orderBook.createBuyMarketOrder(parseUnits("1", 6));

      const afterTreasury = await token.balanceOf(treasury.address);
      const afterUser = await token.balanceOf(user1.address);

      // Treasury should receive fees
      expect(afterTreasury.sub(beforeTreasury)).to.be.gt(0);
      // User should receive less than full amount due to fees
      expect(afterUser.sub(beforeUser)).to.be.lt(parseUnits("100", 18));
    });

    it("should collect fees on sell market orders", async () => {
      const { orderBook, usdc, token, user1, treasury } = await loadFixture(basicFixture);
      const block = await ethers.provider.getBlock("latest");

      // Create a buy order
      await orderBook.connect(user1).createLimitOrder(
        parseUnits("0.01", 6),
        parseUnits("100", 18),
        block.timestamp + 3600,
        OrderType.BUY
      );

      const beforeTreasury = await usdc.balanceOf(treasury.address);
      const beforeUser = await usdc.balanceOf(user1.address);

      // Execute sell market order
      await orderBook.createSellMarketOrder(parseUnits("100", 18));

      const afterTreasury = await usdc.balanceOf(treasury.address);
      const afterUser = await usdc.balanceOf(user1.address);

      // Treasury should receive fees
      expect(afterTreasury.sub(beforeTreasury)).to.be.gt(0);
      // User should receive less than full amount due to fees
      expect(afterUser.sub(beforeUser)).to.be.lt(parseUnits("1", 6));
    });

    it("should allow owner to update fee rates", async () => {
      const { orderBook, owner } = await loadFixture(basicFixture);

      // Update buy fee
      await orderBook.connect(owner).setbuyFeeBips(1000);
      expect(await orderBook.buyFeeBips()).to.equal(1000);

      // Update sell fee
      await orderBook.connect(owner).setsellFeeBips(1000);
      expect(await orderBook.sellFeeBips()).to.equal(1000);

      // Should fail if fee is too high
      await expect(orderBook.connect(owner).setbuyFeeBips(10001)).to.be.revertedWith("Invalid buyFeeBips");
      await expect(orderBook.connect(owner).setsellFeeBips(10001)).to.be.revertedWith("Invalid sellFeeBips");
    });

    it("should allow owner to update treasury address", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);

      await orderBook.connect(owner).setTreasury(user1.address);
      expect(await orderBook.treasury()).to.equal(user1.address);

      // Should fail if address is zero
      await expect(orderBook.connect(owner).setTreasury(ethers.constants.AddressZero)).to.be.revertedWith("Invalid address");
    });
  });

  describe("OrderBook - Oracle functionality", () => {
    it("should get latest rate from oracle", async () => {
      const { orderBook, oracle } = await loadFixture(basicFixture);

      const [bestBidOrder, bestAskOrder] = await orderBook.getLatestRate();
      
      // Oracle should return valid price
      expect(bestBidOrder.price).to.be.gt(0);
      expect(bestAskOrder.price).to.be.gt(0);
    });

    it("should allow owner to update oracle address", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);

      await orderBook.connect(owner).setOracle(user1.address);
      expect(await orderBook.priceOracle()).to.equal(user1.address);

      // Should fail if address is zero
      await expect(orderBook.connect(owner).setOracle(ethers.constants.AddressZero)).to.be.revertedWith("Invalid address");
    });
  });
});