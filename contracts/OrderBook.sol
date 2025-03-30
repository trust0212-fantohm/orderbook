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

    uint256 private constant BASE_BIPS = 10000;
    uint256 private constant price_decimals = 18;
    uint256 public nonce;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;

    address public tokenAddress;
    address public treasury;
    address public oracle; // matic-usd price oracle

    IERC20Upgradeable public token;

    mapping(address => uint256) public OrderCountByUser; // Add Count

    function initialize(
        address _tokenAddress,
        address _treasury,
        address _oracle
    ) public initializer {
        require(_tokenAddress != address(0), "Invalid Token");
        require(_treasury != address(0), "Invalid Token");
        require(_oracle != address(0), "Invalid Token");

        // tokenAddress = _token;
        token = IERC20Upgradeable(_tokenAddress);
        treasury = _treasury;
        oracle = _oracle;
        buyFeeBips = 500;
        sellFeeBips = 500;
        nonce = 0;
    }

    /**
     * @dev Create new buy market order which will be executed instantly
     */
    function createBuyMarketOrder() external payable nonReentrant {
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

        uint256 tokenAmount = 0;
        require(activeSellOrders.length > 0, "Insufficient SellOrders");

        for (uint256 i = activeSellOrders.length - 1; i >= 0; i--) {
            Order storage sellOrder = activeSellOrders[i];
            if (isInvalidOrder(sellOrder)) {
                // remove expired sell orders from active sell order list
                // removeLastFromSellLimitOrder();
                continue;
            }

            uint256 desiredMaticValue = (sellOrder.desiredPrice *
                sellOrder.remainQuantity) / 10 ** price_decimals;
            if (marketOrder.remainMaticValue >= desiredMaticValue) {
                // remove fullfilled order from active sell order list
                // removeLastFromSellLimitOrder();
                // send matic to seller
                (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                    desiredMaticValue,
                    OrderType.SELL
                );
                payable(sellOrder.trader).transfer(realAmount);
                payable(treasury).transfer(feeAmount); // charge fee

                // decrease remain matic value
                marketOrder.remainMaticValue -= desiredMaticValue;
                tokenAmount += sellOrder.remainQuantity;
                // fullfill sell limitOrder
                sellOrder.isFilled = true;
                sellOrder.remainQuantity = 0;
                sellOrder.lastTradeTimestamp = block.timestamp;
            } else {
                // partially fill sell limitOrder
                // send matic to seller

                (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                    marketOrder.remainMaticValue,
                    OrderType.SELL
                );
                payable(sellOrder.trader).transfer(realAmount);
                payable(treasury).transfer(feeAmount);

                uint256 purchasedTokenAmount = (marketOrder.remainMaticValue *
                    10 ** price_decimals) / sellOrder.desiredPrice;
                marketOrder.remainMaticValue = 0;
                // decrease remain token amount of sell limitOrder
                sellOrder.remainQuantity -= purchasedTokenAmount;
                tokenAmount += purchasedTokenAmount;
                sellOrder.lastTradeTimestamp = block.timestamp;
                break;
            }
        }

        if (marketOrder.remainMaticValue > 0) {
            // In this case, sell token supply is insufficient than buy matic amount, so revert
            revert("Insufficient Token Supply");
        }

        fullfilledOrders.push(marketOrder);
        cleanLimitOrders();

        // transfer token to buyer
        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            tokenAmount,
            OrderType.BUY
        );
        token.safeTransfer(msg.sender, _realAmount);
        token.safeTransfer(treasury, _feeAmount);

        OrderCountByUser[msg.sender]++;
    }

    function removeLastFromSellLimitOrder() internal {
        Order memory lastOrder = activeSellOrders[activeSellOrders.length - 1];
        activeSellOrders.pop();
        fullfilledOrders.push(lastOrder);
    }

    /**
     * @dev Create new sell market order which will be executed instantly
     */
    function createSellMarketOrder(uint256 quantity) external nonReentrant {
        require(quantity > 0, "Invalid Token Amount");
        // Token should be left user wallet instantly
        token.safeTransferFrom(
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

        uint256 maticAmount = 0;
        require(activeBuyOrders.length > 0, "Insufficient BuyOrders");
        for (uint256 i = activeBuyOrders.length - 1; i >= 0; i--) {
            Order storage buyOrder = activeBuyOrders[i];
            if (isInvalidOrder(buyOrder)) {
                // remove expired buy orders from active buy order list
                // removeLastFromBuyLimitOrder();
                continue;
            }

            uint256 desiredTokenAmount = buyOrder.remainQuantity;
            if (marketOrder.remainQuantity >= desiredTokenAmount) {
                // remove fullfilled order from active buy order list
                // removeLastFromBuyLimitOrder();
                // send token to buyer
                (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                    desiredTokenAmount,
                    OrderType.BUY
                );
                token.safeTransfer(
                    buyOrder.trader,
                    realAmount
                );
                token.safeTransfer(
                    treasury,
                    feeAmount
                );
                // decrease remain token amount
                marketOrder.remainQuantity -= desiredTokenAmount;
                maticAmount += buyOrder.remainMaticValue;
                // fullfill buy limitOrder
                buyOrder.isFilled = true;
                buyOrder.remainMaticValue = 0;
                buyOrder.remainQuantity = 0;
                buyOrder.lastTradeTimestamp = block.timestamp;
            } else {
                // partially fill buy limitOrder
                // send token to buyer
                (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                    marketOrder.remainQuantity,
                    OrderType.BUY
                );
                token.safeTransfer(
                    buyOrder.trader,
                    realAmount
                );
                token.safeTransfer(
                    treasury,
                    feeAmount
                );
                uint256 usedMaticAmount = (marketOrder.remainQuantity *
                    buyOrder.desiredPrice) / 10 ** price_decimals;
                // decrease remain token amount of sell limitOrder
                buyOrder.remainMaticValue -= usedMaticAmount;
                buyOrder.remainQuantity -= marketOrder.remainQuantity;
                maticAmount += usedMaticAmount;
                buyOrder.lastTradeTimestamp = block.timestamp;
                marketOrder.remainQuantity = 0;
                break;
            }
        }

        if (marketOrder.remainQuantity > 0) {
            // In this case, buy token supply is insufficient than buy matic amount, so revert
            revert("Insufficient market Supply");
        }

        fullfilledOrders.push(marketOrder);
        cleanLimitOrders();

        // transfer token to buyer
        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            maticAmount,
            OrderType.SELL
        );
        payable(msg.sender).transfer(_realAmount);
        payable(treasury).transfer(_feeAmount);

        OrderCountByUser[msg.sender]++;
    }

    function removeLastFromBuyLimitOrder() internal {
        Order memory lastOrder = activeBuyOrders[activeBuyOrders.length - 1];
        activeBuyOrders.pop();
        fullfilledOrders.push(lastOrder);
    }

    /**
     * @dev Create new limit order
     */
    function createLimitOrder(
        uint256 desiredPrice,
        uint256 quantity,
        uint256 timeInForce,
        OrderType orderType
    ) external payable {
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
            token.safeTransferFrom(
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
            executeWeightedLimitOrders();
        }
        OrderCountByUser[msg.sender]++;
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
     * @dev Execute limit orders using weighted matching logic
     */
    function executeWeightedLimitOrders() public nonReentrant {
        cleanLimitOrders();
        require(
            activeBuyOrders.length > 0 && activeSellOrders.length > 0,
            "No limit orders available"
        );

        Order storage buyOrder = activeBuyOrders[activeBuyOrders.length - 1];
        Order storage sellOrder = activeSellOrders[activeSellOrders.length - 1];

        if (buyOrder.desiredPrice >= sellOrder.desiredPrice) {
            uint256 totalTokenAmount = 0;
            for (uint256 i = activeSellOrders.length - 1; i >= 0; i--) {
                Order storage order = activeSellOrders[i];
                if (order.desiredPrice <= buyOrder.desiredPrice) {
                    totalTokenAmount += order.remainQuantity;
                }
            }

            uint256[] memory weights = getOrderWeights(activeSellOrders);

            for (uint256 i = 0; i < activeSellOrders.length; i++) {
                Order storage order = activeSellOrders[i];
                uint256 fillAmount = (totalTokenAmount * weights[i]) / 1e18;

                if (fillAmount > order.remainQuantity) {
                    fillAmount = order.remainQuantity;
                }

                fulfillOrder(order, fillAmount);
            }
        }
    }

    /**
     * @dev Fulfill an order partially or fully
     */
    function fulfillOrder(Order storage order, uint256 fillAmount) internal {
        uint256 maticAmount = (fillAmount * order.desiredPrice) /
            10 ** price_decimals;
        (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
            maticAmount,
            order.orderType
        );

        if (order.orderType == OrderType.SELL) {
            payable(order.trader).transfer(realAmount);
            payable(treasury).transfer(feeAmount);
        } else {
            token.safeTransfer(
                order.trader,
                realAmount
            );
            token.safeTransfer(treasury, feeAmount);
        }

        order.remainQuantity -= fillAmount;
        order.remainMaticValue -= maticAmount;
        order.lastTradeTimestamp = block.timestamp;

        // Mark as filled if fully satisfied
        if (order.remainQuantity == 0) {
            order.isFilled = true;
            cleanLimitOrders(); // Clean up fully filled orders
        }
    }

    /**
     * @dev Calculate order weights based on `createdAt` timestamp
     */
    function getOrderWeights(
        Order[] storage orders
    ) internal view returns (uint256[] memory) {
        uint256 totalAge = 0;
        uint256[] memory weights = new uint256[](orders.length);

        for (uint256 i = 0; i < orders.length; i++) {
            uint256 age = block.timestamp - orders[i].createdAt;
            weights[i] = age;
            totalAge += age;
        }

        for (uint256 i = 0; i < orders.length; i++) {
            weights[i] = (weights[i] * 1e18) / totalAge; // Normalize to 1e18 (100%)
        }

        return weights;
    }

    /**
     * @dev Clean up fully filled or invalid orders
     */
    function cleanLimitOrders() internal {
        while (
            activeBuyOrders.length > 0 &&
            isInvalidOrder(activeBuyOrders[activeBuyOrders.length - 1])
        ) {
            removeLastFromBuyLimitOrder();
        }
        while (
            activeSellOrders.length > 0 &&
            isInvalidOrder(activeSellOrders[activeSellOrders.length - 1])
        ) {
            removeLastFromSellLimitOrder();
        }
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
            for (
                uint256 i = activeBuyOrders.length - 1;
                i >= activeBuyOrders.length - depth;
                i--
            ) {
                bestActiveBuyOrders[i] = activeBuyOrders[i];
            }
            return (price, bestActiveBuyOrders);
        } else {
            Order[] memory bestActiveSellOrders = new Order[](depth);
            if (depth >= activeSellOrders.length) {
                return (price, activeSellOrders);
            }
            for (
                uint256 i = activeSellOrders.length - 1;
                i >= activeSellOrders.length - depth;
                i--
            ) {
                bestActiveSellOrders[i] = activeBuyOrders[i];
            }
            return (price, bestActiveSellOrders);
        }
    }

    function getOrderById(uint256 id) public view returns (Order memory) {
        require(id > 0 && id < nonce, "Invalid Id");
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

    function cancelOrder(uint256 id) external returns (bool) {
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
            token.safeTransfer(
                order.trader,
                order.remainQuantity
            );
        }

        return true;
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
