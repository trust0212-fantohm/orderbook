// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

interface IOrderBook {
    enum OrderType {
        BUY,
        SELL
    }

    struct Order {
        uint256 id;
        address trader; // action performer
        OrderType orderType; // BUY/SELL
        uint256 desiredPrice; // desired token ($ACME) price for trade. This is for limit order
        uint256 quantity; // token amount to trade.
        uint256 remainQuantity; // actual remain token amount
        uint256 maticValue; // matic amount to purchase token. This is available for buy market order only
        uint256 remainMaticValue; // remain matic amount. This is available for buy market order only
        bool isFilled;
        bool isMarketOrder;
        bool isCanceled;
        uint256 timeInForce; //
        uint256 lastTradeTimestamp;
        uint256 createdAt;
    }

    struct RecentOrder {
        uint256 dollars;
        uint256 maticValue;
        uint256 amount;
    }

    event TradeExecuted(
        uint256 indexed buyOrderId,
        uint256 indexed sellOrderId,
        address indexed buyer,
        address seller,
        uint256 price,
        uint256 quantity
    );

    event OrderReverted(uint256 indexed orderId, address indexed trader);

    event OrderCreated(
        uint256 indexed orderId,
        address indexed trader,
        OrderType orderType,
        uint256 desiredPrice,
        uint256 quantity,
        uint256 timeInForce,
        bool isMarket
    );

    event OrderCancelled(
        uint256 indexed orderId,
        address indexed trader,
        OrderType orderType
    );
}
