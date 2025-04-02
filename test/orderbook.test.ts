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
      await expect(orderBook.createBuyMarketOrder({ value: ethers.utils.parseEther("1") })).to.be.revertedWith("Insufficient SellOrders");
      await expect(orderBook.createBuyMarketOrder()).to.be.revertedWith("Insufficient matic amount");

      // sell order
      await expect(orderBook.createSellMarketOrder(ethers.utils.parseEther("100"))).to.be.revertedWith("Insufficient BuyOrders");
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

    it("Create Limit Order - should be reverted with invalid time force value",async () => {
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

    it("Create buy limit order - should be able to create",async () => {
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

    it("Check orderbook status after create new buy limit order: ",async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const result = await orderBook.orderBook(3, OrderType.BUY);
      
      expect(await orderBook.OrderCountByUser(owner.address)).to.be.equals(1);
      expect(result[1].length).to.be.equals(1);
    });

    it("Create sell limit order - should be able to create",async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      await orderBook.createLimitOrder(
        ethers.utils.parseEther("0.2"),
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.SELL,
      );
    });

    it("Check orderbook status after create new sell limit order: ",async () => {
      const { orderBook, owner, user1 } = await loadFixture(basicFixture);
      const result = await orderBook.orderBook(3, OrderType.SELL);

      expect(await orderBook.OrderCountByUser(owner.address)).to.be.equals(2);
      expect(result[1].length).to.be.equals(1);
    });
  });

  describe("Create market order with enough limit orders",() => {
    it("Create buy market order",async () => {
      const { orderBook, owner, user1, token, treasury } = await loadFixture(basicFixture);
      
      const maticAmount = ethers.utils.parseEther("5");
      const {bestAskOrder} = await orderBook.getLatestRate();
      const estimatedPurchasableTokenAmount = parseEther("1").mul(maticAmount).mul(9500).div(10000).div(bestAskOrder.maticValue);
      const beforeTokenBalance = await token.balanceOf(user1.address);
      await orderBook.connect(user1).createBuyMarketOrder({value: maticAmount});
      const afterTokenBalance = await token.balanceOf(user1.address);

      expect(afterTokenBalance.sub(beforeTokenBalance)).to.be.equals(estimatedPurchasableTokenAmount);
    })

    it("Check order book status after buy",async () => {
      const { orderBook, owner, user1, token, treasury } = await loadFixture(basicFixture);
      const res = await orderBook.orderBook(3, OrderType.SELL);
      // console.log(res[1])
    })

    it("Create sell market order",async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      
      const sellTokenAmount = ethers.utils.parseEther("10");
      const {bestBidOrder} = await orderBook.getLatestRate();
      const estimatedSellableMaticAmount = sellTokenAmount.mul(9500).div(10000).mul(bestBidOrder.maticValue).div(parseEther("1"));
      const beforeMaticBalance = await ethers.provider.getBalance(user2.address);
      await orderBook.connect(user2).createSellMarketOrder(sellTokenAmount);
      const afterMaticBalance = await ethers.provider.getBalance(user2.address);

      expect(estimatedSellableMaticAmount.sub(afterMaticBalance.sub(beforeMaticBalance))).to.below(estimatedSellableMaticAmount.div(100).mul(5)); // difference should be under 5%, this is due to gas fee
    })

    it("Check order book status after sell",async () => {
      const { orderBook, owner, user1, token, treasury } = await loadFixture(basicFixture);
      const res = await orderBook.orderBook(3, OrderType.BUY);
      // console.log(res[1])
    })
  })

  describe("Add more limit orders", () => {
    it("Add buy limit orders",async () => {
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
    it("Add sell limit orders",async () => {
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
  
    it("check status",async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      console.log("Buys: ", await orderBook.orderBook(10, OrderType.BUY))
      console.log("Sells: ", await orderBook.orderBook(10, OrderType.SELL))
    })
  }); 
  
  describe("Execute limit orders", () => {
    it("Sell trading",async () => {
      const { orderBook, owner, user1, user2, token, treasury, sellTrader } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      const sellTokenAmount = ethers.utils.parseEther("100");
      const sellPrice = ethers.utils.parseEther("0.15");
      const {bestBidOrder} = await orderBook.getLatestRate();
      const estimatedSellableMaticAmount = sellTokenAmount.mul(9500).div(10000).mul(sellPrice).div(parseEther("1"));
      const beforeMaticBalance = await ethers.provider.getBalance(sellTrader.address);
      
      await orderBook.connect(sellTrader).createLimitOrder(
        sellPrice,
        sellTokenAmount,
        currentBlock.timestamp + 3600,
        OrderType.SELL,
      );

      const afterMaticBalance = await ethers.provider.getBalance(sellTrader.address);

      expect(estimatedSellableMaticAmount.sub(afterMaticBalance.sub(beforeMaticBalance))).to.below(estimatedSellableMaticAmount.div(100).mul(1)); // difference should be under 5%, this is due to gas fee
    })
    it("check status",async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      console.log("Buys: ", await orderBook.orderBook(10, OrderType.BUY))
      // console.log("Sells: ", await orderBook.orderBook(10, OrderType.SELL))
    })
    it("Buy trading",async () => {
      const { orderBook, owner, user1, user2, token, treasury, buyTrader } = await loadFixture(basicFixture);
      const currentBlock = await ethers.provider.getBlock("latest");

      const maticAmount = ethers.utils.parseEther("20");
      const buyPrice = ethers.utils.parseEther("0.2");

      const {bestAskOrder} = await orderBook.getLatestRate();
      const estimatedPurchasableTokenAmount = parseEther("1").mul(maticAmount).mul(9500).div(10000).div(bestAskOrder.maticValue);
      const beforeTokenBalance = await token.balanceOf(buyTrader.address);
      
      await orderBook.connect(buyTrader).createLimitOrder(
        buyPrice,
        ethers.utils.parseEther("100"),
        currentBlock.timestamp + 3600,
        OrderType.BUY,
        {
          value: maticAmount
        }
      );

      const afterTokenBalance = await token.balanceOf(buyTrader.address);

      // expect(afterTokenBalance.sub(beforeTokenBalance)).to.be.equals(estimatedPurchasableTokenAmount);
    })
    it("check status",async () => {
      const { orderBook, owner, user1, user2, token, treasury } = await loadFixture(basicFixture);
      // console.log("Buys: ", await orderBook.orderBook(10, OrderType.BUY))
      console.log("Sells: ", await orderBook.orderBook(10, OrderType.SELL))
    })
  });
})