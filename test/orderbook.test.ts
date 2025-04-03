import { loadFixture } from "ethereum-waffle"
import { basicFixture } from "./fixture"
import { expect } from "chai";
import { ethers } from "hardhat";
import { OrderType } from "./utils/help";
import { parseEther } from "ethers/lib/utils";

describe("Order book test", () => {
  describe("Create Market Order (without limit order)", () => {
    it("Should be failed to create market order without limit order", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);

      // buy order
      await expect(orderBook.createBuyMarketOrder({ value: ethers.utils.parseEther("1") })).to.be.revertedWith("No active sell orders");
      await expect(orderBook.createBuyMarketOrder()).to.be.revertedWith("Insufficient matic amount");

      // sell order
      await expect(orderBook.createSellMarketOrder(ethers.utils.parseEther("100"))).to.be.revertedWith("No active buy orders");
      await expect(orderBook.createSellMarketOrder(0)).to.be.revertedWith("Invalid Token Amount");
    });
  });

  describe("Limit Order", () => {
    it("Create Buy limit order - should be reverted with insufficient matic amount", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await expect(orderBook.createLimitOrder(
        ethers.utils.parseEther("0.1"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.BUY
      )).to.be.revertedWith("Invalid matic amount");
    });

    it("Create Sell limit order - should be reverted with some matic amount", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await expect(orderBook.createLimitOrder(
        ethers.utils.parseEther("0.1"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.SELL,
        {
          value: ethers.utils.parseEther("0.1")
        }
      )).to.be.revertedWith("Invalid matic amount for createLimitSellOrder");
    });

    it("Create Limit Order - should be reverted with invalid time force value", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await expect(orderBook.createLimitOrder(
        ethers.utils.parseEther("0.1"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp - 3600,
        OrderType.BUY,
        {
          value: ethers.utils.parseEther("10")
        }
      )).to.be.revertedWith("Invalid time limit");
    });

    it("Create buy limit order - should be able to create", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await orderBook.createLimitOrder(
        ethers.utils.parseEther("0.1"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.BUY,
        {
          value: ethers.utils.parseEther("10")
        }
      );
    });

    it("Check orderbook status after create new buy limit order: ", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const result = await orderBook.orderBook(3, OrderType.BUY);

      expect(await orderBook.OrderCountByUser(owner.address)).to.be.equals(1);
      expect(result[1].length).to.be.equals(1);
    });

    it("Create sell limit order - should be able to create", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await orderBook.createLimitOrder(
        ethers.utils.parseEther("0.2"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.SELL,
      );
    });

    it("Check orderbook status after create new sell limit order: ", async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const result = await orderBook.orderBook(3, OrderType.SELL);

      expect(await orderBook.OrderCountByUser(owner.address)).to.be.equals(2);
      expect(result[1].length).to.be.equals(1);
    });
  });

  describe("Create market order with enough limit orders", () => {
    // it("Create buy market order", async () => {
    //   const { orderBook, owner, user1, token, treasury } = await loadFixture(basicFixture);

    //   const maticAmount = ethers.utils.parseEther("5");
    //   const { bestAskOrder } = await orderBook.getLatestRate();
    //   const estimatedPurchasableTokenAmount = parseEther("1").mul(maticAmount).mul(9500).div(10000).div(bestAskOrder.maticValue);
    //   const beforeTokenBalance = await token.balanceOf(user1.address);
    //   await orderBook.connect(user1).createBuyMarketOrder({ value: maticAmount });
    //   const afterTokenBalance = await token.balanceOf(user1.address);

    //   expect(afterTokenBalance.sub(beforeTokenBalance)).to.be.equals(estimatedPurchasableTokenAmount);
    // })

    it("Check order book status after buy", async () => {
      const { orderBook, owner, user1, token, treasury } = await loadFixture(basicFixture);
      const res = await orderBook.orderBook(3, OrderType.SELL);
      // console.log(res[1])
    })

    // it("Create sell market order", async () => {
    //   const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);

    //   const sellTokenAmount = ethers.utils.parseEther("10");
    //   const { bestBidOrder } = await orderBook.getLatestRate();
    //   const estimatedSellableMaticAmount = sellTokenAmount.mul(9500).div(10000).mul(bestBidOrder.maticValue).div(parseEther("1"));
    //   const beforeMaticBalance = await ethers.provider.getBalance(user2.address);
    //   await orderBook.connect(user2).createSellMarketOrder(sellTokenAmount);
    //   const afterMaticBalance = await ethers.provider.getBalance(user2.address);

    //   expect(estimatedSellableMaticAmount.sub(afterMaticBalance.sub(beforeMaticBalance))).to.below(estimatedSellableMaticAmount.div(100).mul(5)); // difference should be under 5%, this is due to gas fee
    // })

    it("Check order book status after sell", async () => {
      const { orderBook, owner, user1, token, treasury } = await loadFixture(basicFixture);
      const res = await orderBook.orderBook(3, OrderType.BUY);
      // console.log(res[1])
    })
  })

  describe("Add more limit orders", () => {
    it("Add buy limit orders", async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await orderBook.createLimitOrder(
        ethers.utils.parseEther("0.15"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.BUY,
        {
          value: ethers.utils.parseEther("15")
        }
      );

      await orderBook.createLimitOrder(
        ethers.utils.parseEther("0.11"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.BUY,
        {
          value: ethers.utils.parseEther("11")
        }
      );

      await orderBook.connect(user1).createLimitOrder(
        ethers.utils.parseEther("0.18"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.BUY,
        {
          value: ethers.utils.parseEther("18")
        }
      );

      await orderBook.connect(user2).createLimitOrder(
        ethers.utils.parseEther("0.13"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.BUY,
        {
          value: ethers.utils.parseEther("13")
        }
      );
    })
    it("Add sell limit orders", async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await orderBook.createLimitOrder(
        ethers.utils.parseEther("0.19"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.SELL,
      );

      await orderBook.createLimitOrder(
        ethers.utils.parseEther("0.21"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.SELL,
      );

      await orderBook.connect(user1).createLimitOrder(
        ethers.utils.parseEther("0.25"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.SELL,
      );

      await orderBook.connect(user2).createLimitOrder(
        ethers.utils.parseEther("0.2"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.SELL,
      );
    })

    it("check status", async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      console.log("Buys: ", await orderBook.orderBook(10, OrderType.BUY))
      console.log("Sells: ", await orderBook.orderBook(10, OrderType.SELL))
    })
  });

  describe("Execute limit orders", () => {
    // it("Sell trading", async () => {
    //   const { orderBook, owner, user1, user2, token, treasury, sellTrader } = await loadFixture(basicFixture);
    //   const currentBlock = await ethers.provider.getBlock("latest");

    //   const sellTokenAmount = ethers.utils.parseEther("100");
    //   const sellPrice = ethers.utils.parseEther("0.15");
    //   const { bestBidOrder } = await orderBook.getLatestRate();
    //   const estimatedSellableMaticAmount = sellTokenAmount.mul(9500).div(10000).mul(sellPrice).div(parseEther("1"));
    //   const beforeMaticBalance = await ethers.provider.getBalance(sellTrader.address);

    //   await orderBook.connect(sellTrader).createLimitOrder(
    //     sellPrice,
    //     sellTokenAmount,
    //     currentBlock.timestamp + 3600,
    //     OrderType.SELL,
    //   );

    //   const afterMaticBalance = await ethers.provider.getBalance(sellTrader.address);

    //   expect(estimatedSellableMaticAmount.sub(afterMaticBalance.sub(beforeMaticBalance))).to.below(estimatedSellableMaticAmount.div(100).mul(1)); // difference should be under 5%, this is due to gas fee
    // })
    it("check status", async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      console.log("Buys: ", await orderBook.orderBook(10, OrderType.BUY))
      // console.log("Sells: ", await orderBook.orderBook(10, OrderType.SELL))
    })
    // it("Buy trading", async () => {
    //   const { orderBook, owner, user1, user2, token, treasury, buyTrader } = await loadFixture(basicFixture);
    //   const currentBlock = await ethers.provider.getBlock("latest");

    //   const maticAmount = ethers.utils.parseEther("20");
    //   const buyPrice = ethers.utils.parseEther("0.2");

    //   const { bestAskOrder } = await orderBook.getLatestRate();
    //   const estimatedPurchasableTokenAmount = parseEther("1").mul(maticAmount).mul(9500).div(10000).div(bestAskOrder.maticValue);
    //   const beforeTokenBalance = await token.balanceOf(buyTrader.address);

    //   await orderBook.connect(buyTrader).createLimitOrder(
    //     buyPrice,
    //     ethers.utils.parseEther("100"),
    //     currentBlock.timestamp + 3600,
    //     OrderType.BUY,
    //     {
    //       value: maticAmount
    //     }
    //   );

    //   const afterTokenBalance = await token.balanceOf(buyTrader.address);

    //   // expect(afterTokenBalance.sub(beforeTokenBalance)).to.be.equals(estimatedPurchasableTokenAmount);
    // })
    it("check status", async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      // console.log("Buys: ", await orderBook.orderBook(10, OrderType.BUY))
      console.log("Sells: ", await orderBook.orderBook(10, OrderType.SELL))
    })
  });

  describe("Weighted Matching Logic", () => {
    it("Sell market order matched against multiple buy limit orders (same price, time-weighted)", async () => {
      const { orderBook, user1, user2, user3, sellTrader } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");
      const buyPrice = parseEther("0.1");
      const qty = parseEther("100");

      // BUY limit orders at same price
      await orderBook.connect(user1).createLimitOrder(buyPrice, qty, currentBlock.timestamp + 3600, OrderType.BUY, {
        value: buyPrice.mul(qty).div(parseEther("1")),
      });

      await ethers.provider.send("evm_increaseTime", [5]);
      await ethers.provider.send("evm_mine", []);

      await orderBook.connect(user2).createLimitOrder(buyPrice, qty, currentBlock.timestamp + 3600, OrderType.BUY, {
        value: buyPrice.mul(qty).div(parseEther("1")),
      });

      await ethers.provider.send("evm_increaseTime", [5]);
      await ethers.provider.send("evm_mine", []);

      await orderBook.connect(user3).createLimitOrder(buyPrice, qty, currentBlock.timestamp + 3600, OrderType.BUY, {
        value: buyPrice.mul(qty).div(parseEther("1")),
      });

      // SELL market order (should match all 3)
      const sellAmount = parseEther("150");
      const beforeBal1 = await orderBook.provider.getBalance(user1.address);
      const beforeBal2 = await orderBook.provider.getBalance(user2.address);
      const beforeBal3 = await orderBook.provider.getBalance(user3.address);

      await orderBook.connect(sellTrader).createSellMarketOrder(sellAmount);

      const afterBal1 = await orderBook.provider.getBalance(user1.address);
      const afterBal2 = await orderBook.provider.getBalance(user2.address);
      const afterBal3 = await orderBook.provider.getBalance(user3.address);

      const received1 = afterBal1.sub(beforeBal1);
      const received2 = afterBal2.sub(beforeBal2);
      const received3 = afterBal3.sub(beforeBal3);

      console.log("Received MATIC from Sell (Weighted by time):", {
        user1: ethers.utils.formatEther(received1),
        user2: ethers.utils.formatEther(received2),
        user3: ethers.utils.formatEther(received3),
      });

      expect(received1.gt(received2)).to.be.true;
      expect(received2.gt(received3)).to.be.true;
    });

    // it("Market order with partial fill", async () => {
    //   const { orderBook, token, user1, user2, treasury } = await loadFixture(basicFixture);
    //   const currentBlock = await ethers.provider.getBlock("latest");

    //   // SELL limit order (100 tokens @ 0.2 MATIC each)
    //   const sellPrice = parseEther("0.2");
    //   const sellQty = parseEther("100");
    //   await orderBook.connect(user1).createLimitOrder(sellPrice, sellQty, currentBlock.timestamp + 3600, OrderType.SELL);

    //   // BUY market order for ~50 tokens
    //   const tokenQty = parseEther("50");
    //   const totalMatic = tokenQty.mul(sellPrice).div(parseEther("1"));
    //   const buyMaticAmount = totalMatic.add(parseEther("0.01")); // buffer for fees

    //   const beforeTokenBalance = await token.balanceOf(user2.address);
    //   await orderBook.connect(user2).createBuyMarketOrder({ value: buyMaticAmount });
    //   const afterTokenBalance = await token.balanceOf(user2.address);

    //   const tokenReceived = afterTokenBalance.sub(beforeTokenBalance);
    //   console.log("Tokens received by market buyer:", ethers.utils.formatEther(tokenReceived));

    //   expect(tokenReceived.gt(parseEther("45"))).to.be.true;
    //   expect(tokenReceived.lt(parseEther("55"))).to.be.true;
    // });

    // it("Matching respects price priority before time weighting", async () => {
    //   const { orderBook, user1, user2, user3, treasury } = await loadFixture(basicFixture);
    //   const currentBlock = await ethers.provider.getBlock("latest");

    //   const qty = parseEther("100");
    //   const lowPrice = parseEther("0.1");
    //   const highPrice = parseEther("0.2");

    //   // 2 SELL limit orders @ lowPrice, 1 @ highPrice
    //   await orderBook.connect(user1).createLimitOrder(lowPrice, qty, currentBlock.timestamp + 3600, OrderType.SELL);
    //   await ethers.provider.send("evm_increaseTime", [5]);
    //   await ethers.provider.send("evm_mine", []);
    //   await orderBook.connect(user2).createLimitOrder(lowPrice, qty, currentBlock.timestamp + 3600, OrderType.SELL);
    //   await ethers.provider.send("evm_increaseTime", [5]);
    //   await ethers.provider.send("evm_mine", []);
    //   await orderBook.connect(user3).createLimitOrder(highPrice, qty, currentBlock.timestamp + 3600, OrderType.SELL);

    //   // BUY market order for enough MATIC to fill ~200 tokens @ lowPrice
    //   const totalMatic = qty.mul(lowPrice).mul(2).div(parseEther("1")); // fill 2 lowest
    //   const buffer = parseEther("0.01");
    //   await orderBook.connect(treasury).createBuyMarketOrder({ value: totalMatic.add(buffer) });

    //   const user3Orders = await orderBook.getOrdersByUser(user3.address);
    //   const highPriceOrder = user3Orders[1]; // should be second
    //   expect(highPriceOrder.desiredPrice).to.equal(highPrice);
    //   expect(highPriceOrder.remainQuantity).to.equal(qty);
    //   expect(highPriceOrder.isFilled).to.be.false;

    //   console.log("High-price order untouched as expected.");
    // });
  });

})