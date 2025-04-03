// SPDX-License-Identifier: MIT

pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {IOracle} from "./interfaces/IOracle.sol";

contract OrderBook is
    Initializable,
    IOrderBook,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    Order[] public activeBuyOrders;
    Order[] public activeSellOrders;
    Order[] public fullfilledOrders;

    uint256 public nonce;
    uint256 private constant BASE_BIPS = 10000;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;
    uint256 private constant price_decimals = 18;

    address public tokenAddress;
    address public treasury;
    address public oracle; // matic-usd price oracle

    mapping(address => uint256) public OrderCountByUser; // Add Count

    function initialize(
        address _token,
        address _treasury,
        address _oracle
    ) public initializer {
        require(_token != address(0), "Invalid Token");
        require(_treasury != address(0), "Invalid Token");
        require(_oracle != address(0), "Invalid Token");

        __Ownable_init();
        __ReentrancyGuard_init();

        tokenAddress = _token;
        treasury = _treasury;
        oracle = _oracle;
        buyFeeBips = 500;
        sellFeeBips = 500;
        nonce = 0;
    }

    /**
     * @dev Create a new buy market order and distribute volume proportionally
     */
    function createBuyMarketOrder()
        external
        payable
        nonReentrant
        returns (uint256)
    {
        require(msg.value > 0, "Insufficient matic amount");

        Order memory marketOrder = Order(
            nonce,
            msg.sender,
            OrderType.BUY,
            0,
            0,
            0,
            msg.value,
            msg.value,
            false,
            true,
            false,
            0,
            0,
            block.timestamp
        );

        nonce++;

        require(activeSellOrders.length > 0, "No active sell orders");

        emit OrderCreated(
            marketOrder.id,
            msg.sender,
            OrderType.BUY,
            0, // price not applicable
            msg.value,
            0, // no timeInForce for market
            true
        );

        distributeVolumeByPrice(marketOrder.remainMaticValue, OrderType.SELL);
        OrderCountByUser[msg.sender]++;

        return marketOrder.id;
    }

    /**
     * @dev Create a new sell market order and distribute volume proportionally
     */
    function createSellMarketOrder(
        uint256 quantity
    ) external nonReentrant returns (uint256) {
        require(quantity > 0, "Invalid Token Amount");

        IERC20Upgradeable(tokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            quantity
        );

        Order memory marketOrder = Order(
            nonce,
            msg.sender,
            OrderType.SELL,
            0,
            quantity,
            quantity,
            0,
            0,
            false,
            true,
            false,
            0,
            0,
            block.timestamp
        );

        nonce++;

        require(activeBuyOrders.length > 0, "No active buy orders");

        emit OrderCreated(
            marketOrder.id,
            msg.sender,
            OrderType.SELL,
            0, // price not applicable
            quantity,
            0, // no timeInForce for market
            true
        );

        distributeVolumeByPrice(marketOrder.remainQuantity, OrderType.BUY);
        OrderCountByUser[msg.sender]++;

        return marketOrder.id;
    }

    /**
     * @dev Create new limit order
     */
    function createLimitOrder(
        uint256 desiredPrice,
        uint256 quantity,
        uint256 timeInForce,
        OrderType orderType
    ) external payable returns (uint256) {
        if (orderType == OrderType.BUY) {
            require(
                msg.value == (desiredPrice * quantity) / 10 ** price_decimals,
                "Invalid matic amount"
            );
        } else {
            require(
                msg.value == 0,
                "Invalid matic amount for createLimitSellOrder"
            );
            IERC20Upgradeable(tokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                quantity
            );
        }
        require(timeInForce > block.timestamp, "Invalid time limit");

        Order memory newOrder = Order(
            nonce,
            msg.sender,
            orderType,
            desiredPrice,
            quantity,
            quantity,
            msg.value,
            msg.value,
            false,
            false,
            false,
            timeInForce,
            0,
            block.timestamp
        );

        nonce++;

        emit OrderCreated(
            newOrder.id,
            msg.sender,
            orderType,
            desiredPrice,
            quantity,
            timeInForce,
            false
        );

        // Insert newOrder into active sell/buy limit order list. It should be sorted by desiredPrice
        // For Sell orders, we sort it DESC, so it should be [9,8,.., 2,1,0]
        // For Buy orders, we sort it ASC, so it should be [0,1,2,...,8,9]
        // In this way, we iterate order list from end, and pop the last order from active order list
        if (orderType == OrderType.BUY) {
            insertBuyLimitOrder(newOrder);
        } else {
            insertSellLimitOrder(newOrder);
        }

        if (activeBuyOrders.length > 0 && activeSellOrders.length > 0) {
            executeLimitOrders();
        }

        OrderCountByUser[msg.sender]++;

        return newOrder.id;
    }

    // Sort ASC [0, 1, 2, ...]
    function insertBuyLimitOrder(Order memory newLimitBuyOrder) internal {
        uint256 i = activeBuyOrders.length;

        activeBuyOrders.push(newLimitBuyOrder);

        while (
            i > 0 &&
            activeBuyOrders[i - 1].desiredPrice > newLimitBuyOrder.desiredPrice
        ) {
            activeBuyOrders[i] = activeBuyOrders[i - 1];
            i--;
        }

        activeBuyOrders[i] = newLimitBuyOrder;
    }

    // Sort DESC [9, 8, ..., 1, 0]
    function insertSellLimitOrder(Order memory newLimitSellOrder) internal {
        uint256 i = activeSellOrders.length;

        activeSellOrders.push(newLimitSellOrder);

        while (
            i > 0 &&
            activeSellOrders[i - 1].desiredPrice <
            newLimitSellOrder.desiredPrice
        ) {
            activeSellOrders[i] = activeSellOrders[i - 1];
            i--;
        }

        activeSellOrders[i] = newLimitSellOrder;
    }

    /**
     * @dev Execute limit orders with weighted distribution logic
     */
    function executeLimitOrders() public nonReentrant {
        cleanLimitOrders();

        require(
            activeBuyOrders.length > 0 && activeSellOrders.length > 0,
            "No active limit orders"
        );

        uint256 remainingQuantity;
        uint256 priceToMatch;

        while (
            activeBuyOrders.length > 0 &&
            activeSellOrders.length > 0 &&
            activeBuyOrders[activeBuyOrders.length - 1].desiredPrice >=
            activeSellOrders[activeSellOrders.length - 1].desiredPrice
        ) {
            Order storage buyOrder = activeBuyOrders[
                activeBuyOrders.length - 1
            ];
            Order storage sellOrder = activeSellOrders[
                activeSellOrders.length - 1
            ];

            // Determine the volume that can be matched
            remainingQuantity = buyOrder.remainQuantity >=
                sellOrder.remainQuantity
                ? sellOrder.remainQuantity
                : buyOrder.remainQuantity;

            priceToMatch = sellOrder.desiredPrice;

            // Distribute volume for both buy and sell orders at this price
            distributeVolumeByPrice(remainingQuantity, OrderType.BUY);
            distributeVolumeByPrice(remainingQuantity, OrderType.SELL);
        }
    }

    /**
     * @dev Clean invalid orders from order book
     */
    function cleanLimitOrders() internal {
        while (
            activeBuyOrders.length > 0 &&
            isInvalidOrder(activeBuyOrders[activeBuyOrders.length - 1])
        ) {
            removeOrder(activeBuyOrders, activeBuyOrders.length - 1);
        }
        while (
            activeSellOrders.length > 0 &&
            isInvalidOrder(activeSellOrders[activeSellOrders.length - 1])
        ) {
            removeOrder(activeSellOrders, activeSellOrders.length - 1);
        }
    }

    /**
     * @dev Distribute volume across orders with different prices and handle transfers.
     * Processes orders price-by-price until the volume is fully allocated.
     */
    function distributeVolumeByPrice(
        uint256 volume,
        OrderType orderType
    ) internal {
        Order[] storage orders = orderType == OrderType.BUY
            ? activeSellOrders
            : activeBuyOrders;

        uint256 remainingVolume = volume;
        uint256 lastProcessedPrice = type(uint256).max;

        for (uint256 i = orders.length; i > 0; i--) {
            Order storage refOrder = orders[i - 1];
            uint256 price = refOrder.desiredPrice;

            if (price == lastProcessedPrice) continue;
            lastProcessedPrice = price;

            (
                uint256[] memory indexes,
                uint256[] memory weights,
                uint256 totalWeight
            ) = getOrderWeightsAtPrice(orders, price);

            if (totalWeight == 0) continue;

            uint256 distributedVolume = 0;

            for (uint256 j = 0; j < indexes.length; j++) {
                if (remainingVolume == 0) break;

                // uint256 orderIndex = indexes[j];
                Order storage o = orders[indexes[j]];
                uint256 weightedVolume = (volume * weights[j]) / totalWeight;

                // Last order gets the dust
                // Clamp last fill
                if (
                    j == indexes.length - 1 ||
                    distributedVolume + weightedVolume > volume
                ) {
                    weightedVolume = remainingVolume;
                }

                distributedVolume += weightedVolume;

                if (orderType == OrderType.BUY) {
                    remainingVolume -= processBuyVolume(
                        o,
                        weightedVolume,
                        indexes[j],
                        msg.sender
                    );
                } else {
                    remainingVolume -= processSellVolume(
                        o,
                        weightedVolume,
                        indexes[j],
                        msg.sender
                    );
                }
            }

            // require(remainingVolume == 0, "Insufficient market depth");
        }
    }

    function processBuyVolume(
        Order storage o,
        uint256 weightedVolume,
        uint256 orderIndex,
        address marketTrader
    ) internal returns (uint256 spentMatic) {
        uint256 tokenAmount = (weightedVolume * 10 ** price_decimals) /
            o.desiredPrice;

        if (tokenAmount >= o.remainQuantity) {
            uint256 maticToPay = (o.remainQuantity * o.desiredPrice) /
                10 ** price_decimals;
            handleTrade(OrderType.BUY, marketTrader, o, maticToPay);
            o.remainQuantity = 0;
            o.isFilled = true;
            o.lastTradeTimestamp = block.timestamp;
            fullfilledOrders.push(o);
            removeOrder(activeSellOrders, orderIndex);
            return maticToPay;
        } else {
            handleTrade(OrderType.BUY, marketTrader, o, weightedVolume);
            o.remainQuantity -= tokenAmount;
            o.lastTradeTimestamp = block.timestamp;
            return weightedVolume;
        }
    }

    function processSellVolume(
        Order storage o,
        uint256 weightedVolume,
        uint256 orderIndex,
        address marketTrader
    ) internal returns (uint256 usedTokens) {
        if (weightedVolume >= o.remainQuantity) {
            handleTrade(OrderType.SELL, marketTrader, o, o.remainQuantity);
            uint256 used = o.remainQuantity;
            o.remainQuantity = 0;
            o.isFilled = true;
            o.lastTradeTimestamp = block.timestamp;
            fullfilledOrders.push(o);
            removeOrder(activeBuyOrders, orderIndex);
            return used;
        } else {
            handleTrade(OrderType.SELL, marketTrader, o, weightedVolume);
            o.remainQuantity -= weightedVolume;
            o.lastTradeTimestamp = block.timestamp;
            return weightedVolume;
        }
    }

    /**
     * @dev Handle transfer of MATIC and tokens between buyer, seller, and treasury.
     */
    function handleTrade(
        OrderType marketOrderType,
        address marketTrader,
        Order storage counterOrder,
        uint256 tradeValue
    ) internal {
        if (marketOrderType == OrderType.BUY) {
            // Market buyer sends MATIC, receives tokens
            // Counterparty is a SELL limit order (has tokens, receives MATIC)

            (uint256 realMatic, uint256 maticFee) = getAmountDeductFee(
                tradeValue,
                OrderType.SELL
            );
            payable(counterOrder.trader).transfer(realMatic);
            if (maticFee > 0) {
                payable(treasury).transfer(maticFee);
            }

            // Convert MATIC to tokens
            uint256 tokenAmount = (tradeValue * 10 ** price_decimals) /
                counterOrder.desiredPrice;
            (uint256 realTokens, uint256 tokenFee) = getAmountDeductFee(
                tokenAmount,
                OrderType.BUY
            );

            IERC20Upgradeable(tokenAddress).safeTransfer(
                marketTrader,
                realTokens
            );
            if (tokenFee > 0) {
                IERC20Upgradeable(tokenAddress).safeTransfer(
                    treasury,
                    tokenFee
                );
            }
        } else {
            // Market seller sends tokens, receives MATIC
            // Counterparty is a BUY limit order (has MATIC, receives tokens)

            require(
                counterOrder.remainMaticValue >= tradeValue,
                "Order has insufficient MATIC"
            );

            (uint256 realTokens, uint256 tokenFee) = getAmountDeductFee(
                tradeValue,
                OrderType.BUY
            );
            IERC20Upgradeable(tokenAddress).safeTransfer(
                counterOrder.trader,
                realTokens
            );
            if (tokenFee > 0) {
                IERC20Upgradeable(tokenAddress).safeTransfer(
                    treasury,
                    tokenFee
                );
            }

            uint256 maticAmount = (tradeValue * counterOrder.desiredPrice) /
                10 ** price_decimals;
            (uint256 realMatic, uint256 maticFee) = getAmountDeductFee(
                maticAmount,
                OrderType.SELL
            );

            payable(marketTrader).transfer(realMatic);
            if (maticFee > 0) {
                payable(treasury).transfer(maticFee);
            }

            counterOrder.remainMaticValue -= maticAmount;
        }
    }

    /**
     * @dev Calculate weights based on the order's listing time
     */
    function getOrderWeightsAtPrice(
        Order[] storage orders,
        uint256 price
    )
        internal
        view
        returns (
            uint256[] memory indexes,
            uint256[] memory weights,
            uint256 totalWeight
        )
    {
        uint256 count = 0;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].desiredPrice == price) {
                count++;
            }
        }

        indexes = new uint256[](count);
        weights = new uint256[](count);
        totalWeight = 0;

        uint256 idx = 0;
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i].desiredPrice == price) {
                uint256 weight = block.timestamp - orders[i].createdAt;
                indexes[idx] = i;
                weights[idx] = weight;
                totalWeight += weight;
                idx++;
            }
        }
    }

    /**
     * @dev Remove an order from the array by index
     */
    function removeOrder(Order[] storage orders, uint256 index) internal {
        require(index < orders.length, "Index out of bounds");

        for (uint256 i = index; i < orders.length - 1; i++) {
            orders[i] = orders[i + 1];
        }
        orders.pop();
    }

    function isInvalidOrder(Order memory order) public view returns (bool) {
        return
            order.isCanceled ||
            order.isFilled ||
            order.timeInForce < block.timestamp ||
            order.remainQuantity == 0;
    }

    function getLatestRate()
        external
        view
        returns (
            RecentOrder memory bestBidOrder,
            RecentOrder memory bestAskOrder
        )
    {
        (, uint256 price) = IOracle(oracle).getLatestRoundData();

        if (activeBuyOrders.length > 0) {
            Order memory order = activeBuyOrders[activeBuyOrders.length - 1];
            bestBidOrder = RecentOrder(
                price * order.desiredPrice,
                order.desiredPrice,
                order.remainQuantity
            );
        }

        if (activeSellOrders.length > 0) {
            Order memory order = activeSellOrders[activeSellOrders.length - 1];
            bestAskOrder = RecentOrder(
                price * order.desiredPrice,
                order.desiredPrice,
                order.remainQuantity
            );
        }
    }

    function orderBook(
        uint256 depth,
        OrderType orderType
    ) external view returns (uint256, Order[] memory) {
        (, uint256 price) = IOracle(oracle).getLatestRoundData();

        if (orderType == OrderType.BUY) {
            Order[] memory bestActiveBuyOrders = new Order[](depth);
            if (depth >= activeBuyOrders.length) {
                return (price, activeBuyOrders);
            }
            for (uint256 i = 0; i < depth && i < activeBuyOrders.length; i++) {
                bestActiveBuyOrders[i] = activeBuyOrders[
                    activeBuyOrders.length - 1 - i
                ];
            }
            return (price, bestActiveBuyOrders);
        } else {
            Order[] memory bestActiveSellOrders = new Order[](depth);
            if (depth >= activeSellOrders.length) {
                return (price, activeSellOrders);
            }
            for (uint256 i = 0; i < depth && i < activeSellOrders.length; i++) {
                bestActiveSellOrders[i] = activeSellOrders[
                    activeSellOrders.length - 1 - i
                ];
            }
            return (price, bestActiveSellOrders);
        }
    }

    function getOrderById(uint256 id) public view returns (Order memory) {
        require(id < nonce, "Invalid Id");
        for (uint256 i = 0; i < activeBuyOrders.length; i++) {
            Order memory order = activeBuyOrders[i];
            if (id == order.id) {
                return order;
            }
        }
        for (uint256 i = 0; i < activeSellOrders.length; i++) {
            Order memory order = activeSellOrders[i];
            if (id == order.id) {
                return order;
            }
        }
        for (uint256 i = 0; i < fullfilledOrders.length; i++) {
            Order memory order = fullfilledOrders[i];
            if (id == order.id) {
                return order;
            }
        }

        revert("Invalid Order");
    }

    function getOrdersByUser(
        address user
    ) external view returns (Order[] memory, Order[] memory, Order[] memory) {
        require(OrderCountByUser[user] > 0, "User did not make any order");
        Order[] memory activeBuyOrdersByUser = new Order[](
            OrderCountByUser[user]
        );
        uint256 k;
        for (uint256 i = 0; i < activeBuyOrders.length; i++) {
            Order memory order = activeBuyOrders[i];
            if (user == order.trader) {
                activeBuyOrdersByUser[k] = order;
                k++;
            }
        }
        uint256 toDrop1 = OrderCountByUser[user] - k;
        if (toDrop1 > 0) {
            assembly {
                mstore(
                    activeBuyOrdersByUser,
                    sub(mload(activeBuyOrdersByUser), toDrop1)
                )
            }
        }
        k = 0;

        Order[] memory activeSellOrdersByUser = new Order[](
            OrderCountByUser[user]
        );
        for (uint256 i = 0; i < activeSellOrders.length; i++) {
            Order memory order = activeSellOrders[i];
            if (user == order.trader) {
                activeSellOrdersByUser[k] = order;
                k++;
            }
        }
        uint256 toDrop2 = OrderCountByUser[user] - k;
        if (toDrop2 > 0) {
            assembly {
                mstore(
                    activeSellOrdersByUser,
                    sub(mload(activeSellOrdersByUser), toDrop2)
                )
            }
        }
        k = 0;

        Order[] memory fullfilledOrdersByUser = new Order[](
            OrderCountByUser[user]
        );
        for (uint256 i = 0; i < fullfilledOrders.length; i++) {
            Order memory order = fullfilledOrders[i];
            if (user == order.trader) {
                fullfilledOrdersByUser[k] = order;
                k++;
            }
        }
        uint256 toDrop3 = OrderCountByUser[user] - k;
        if (toDrop3 > 0) {
            assembly {
                mstore(
                    fullfilledOrdersByUser,
                    sub(mload(fullfilledOrdersByUser), toDrop3)
                )
            }
        }

        return (
            activeBuyOrdersByUser,
            activeSellOrdersByUser,
            fullfilledOrdersByUser
        );
    }

    function cancelOrder(uint256 id) external {
        require(id < nonce, "Invalid Id");
        (OrderType orderType, uint256 i) = getIndex(id);
        Order storage order = orderType == OrderType.BUY
            ? activeBuyOrders[i]
            : activeSellOrders[i];
        require(order.trader == msg.sender, "Not owner of Order");

        order.isCanceled = true;

        if (orderType == OrderType.BUY) {
            payable(order.trader).transfer(order.remainMaticValue);
        } else {
            IERC20Upgradeable(tokenAddress).safeTransfer(
                order.trader,
                order.remainQuantity
            );
        }

        emit OrderCancelled(id, msg.sender, orderType);
    }

    function getIndex(uint256 id) public view returns (OrderType, uint256) {
        for (uint256 i = 0; i < activeBuyOrders.length; i++) {
            Order memory order = activeBuyOrders[i];
            if (id == order.id) {
                return (OrderType.BUY, i);
            }
        }

        for (uint256 i = 0; i < activeSellOrders.length; i++) {
            Order memory order = activeSellOrders[i];
            if (id == order.id) {
                return (OrderType.SELL, i);
            }
        }

        revert("Invalid Id");
    }

    function setbuyFeeBips(uint256 _buyFeeBips) external onlyOwner {
        require(buyFeeBips != _buyFeeBips, "Same buyFeeBips");
        require(_buyFeeBips < BASE_BIPS, "Invalid buyFeeBips");

        buyFeeBips = _buyFeeBips;
    }

    function setsellFeeBips(uint256 _sellFeeBips) external onlyOwner {
        require(sellFeeBips != _sellFeeBips, "Invalid sellFeeBips");
        require(_sellFeeBips < BASE_BIPS, "Invalid sellFeeBips");

        sellFeeBips = _sellFeeBips;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid address");

        treasury = _treasury;
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid address");
        oracle = _oracle;
    }

    function getAmountDeductFee(
        uint256 amount,
        OrderType orderType
    ) internal view returns (uint256 realAmount, uint256 feeAmount) {
        uint256 feeBips = orderType == OrderType.BUY ? buyFeeBips : sellFeeBips;

        realAmount = (amount * (BASE_BIPS - feeBips)) / BASE_BIPS;
        feeAmount = amount - realAmount;
    }
}
