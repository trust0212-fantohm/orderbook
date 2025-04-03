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

    address public tokenAddress;

    uint256 public nonce;
    uint256 private constant BASE_BIPS = 10000;
    uint256 public buyFeeBips;
    uint256 public sellFeeBips;
    // Price decimals. We set price wei unit. so 1 $ACME = 0.01 $Matic means price = 10 ** 16.
    uint256 private constant price_decimals = 18;
    address public treasury;
    address public oracle; // matic-usd price oracle

    mapping(address => uint256) public OrderCountByUser; // Add Count

    function initialize(
        address _token,
        address _treasury,
        address _oracle
    ) public initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        require(_token != address(0), "Invalid Token");
        require(_treasury != address(0), "Invalid Token");
        require(_oracle != address(0), "Invalid Token");
        tokenAddress = _token;
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

        require(activeSellOrders.length > 0, "No active sell orders");

        uint256 totalTokens = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeSellOrders.length;
            i > 0 && marketOrder.remainMaticValue > 0;

        ) {
            uint256 currentPrice = activeSellOrders[i - 1].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && activeSellOrders[j - 1].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order storage o = activeSellOrders[k];
                if (!isInvalidOrder(o)) {
                    uint256 w = nowTime - o.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 tokenFilled,
                uint256 maticUsed
            ) = distributeBuyOrderAcrossPriceLevel(
                    marketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalTokens += tokenFilled;
            marketOrder.remainMaticValue -= maticUsed;

            i = start; // move to next price level
        }

        if (marketOrder.remainMaticValue > 0) {
            revert("Insufficient Token Supply");
        }

        fullfilledOrders.push(marketOrder);
        cleanLimitOrders();

        (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
            totalTokens,
            OrderType.BUY
        );
        IERC20Upgradeable(tokenAddress).safeTransfer(msg.sender, _realAmount);
        IERC20Upgradeable(tokenAddress).safeTransfer(treasury, _feeAmount);

        OrderCountByUser[msg.sender]++;
    }

    function distributeBuyOrderAcrossPriceLevel(
        Order memory marketOrderMem,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 tokenFilled, uint256 maticUsed) {
        uint256 remainMaticValue = marketOrderMem.remainMaticValue;
        uint256 remainTotalWeight = totalWeight;
        for (uint256 k = start; k < end && remainMaticValue > 0; k++) {
            Order storage sellOrder = activeSellOrders[k];
            if (isInvalidOrder(sellOrder)) continue;

            uint256 weight = nowTime - sellOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 maticShare = (remainMaticValue * weight) /
                remainTotalWeight;

            uint256 tokenQty = (maticShare * 10 ** price_decimals) /
                currentPrice;
            if (tokenQty > sellOrder.remainQuantity) {
                tokenQty = sellOrder.remainQuantity;
                maticShare = (tokenQty * currentPrice) / 10 ** price_decimals;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                maticShare,
                OrderType.SELL
            );
            payable(sellOrder.trader).transfer(realAmount);
            payable(treasury).transfer(feeAmount);

            sellOrder.remainQuantity -= tokenQty;
            sellOrder.lastTradeTimestamp = block.timestamp;

            if (sellOrder.remainQuantity == 0) {
                sellOrder.isFilled = true;
            }

            tokenFilled += tokenQty;
            maticUsed += maticShare;
            remainTotalWeight -= weight;
            remainMaticValue -= maticShare;
        }
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

        uint256 totalMatic = 0;
        uint256 nowTime = block.timestamp;

        for (
            uint256 i = activeBuyOrders.length;
            i > 0 && marketOrder.remainQuantity > 0;

        ) {
            uint256 currentPrice = activeBuyOrders[i - 1].desiredPrice;
            uint256 j = i;

            while (
                j > 0 && activeBuyOrders[j - 1].desiredPrice == currentPrice
            ) {
                j--;
            }

            uint256 start = j;
            uint256 end = i;

            // Compute total time weight for this price group
            uint256 totalWeight = 0;
            for (uint256 k = start; k < end; k++) {
                Order storage o = activeBuyOrders[k];
                if (!isInvalidOrder(o)) {
                    uint256 w = nowTime - o.createdAt;
                    if (w == 0) w = 1;
                    totalWeight += w;
                }
            }

            // Apply time-weighted matching
            (
                uint256 maticFilled,
                uint256 quantityFilled
            ) = distributeSellOrderAcrossPriceLevel(
                    marketOrder,
                    currentPrice,
                    start,
                    end,
                    totalWeight,
                    nowTime
                );

            totalMatic += maticFilled;
            marketOrder.remainQuantity -= quantityFilled;

            i = start;
        }

        if (marketOrder.remainQuantity > 0) {
            revert("Insufficient market supply");
        }

        fullfilledOrders.push(marketOrder);
        cleanLimitOrders();

        (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
            totalMatic,
            OrderType.SELL
        );
        payable(msg.sender).transfer(realAmount);
        payable(treasury).transfer(feeAmount);

        OrderCountByUser[msg.sender]++;
    }

    function distributeSellOrderAcrossPriceLevel(
        Order memory marketOrderMem,
        uint256 currentPrice,
        uint256 start,
        uint256 end,
        uint256 totalWeight,
        uint256 nowTime
    ) internal returns (uint256 maticFilled, uint256 quantityFilled) {
        for (
            uint256 k = start;
            k < end && marketOrderMem.remainQuantity > 0;
            k++
        ) {
            Order storage buyOrder = activeBuyOrders[k];
            if (isInvalidOrder(buyOrder)) continue;

            uint256 weight = nowTime - buyOrder.createdAt;
            if (weight == 0) weight = 1;

            uint256 share = (marketOrderMem.remainQuantity * weight) /
                totalWeight;
            if (share > buyOrder.remainQuantity) {
                share = buyOrder.remainQuantity;
            }

            uint256 maticValue = (share * currentPrice) / 10 ** price_decimals;
            if (maticValue > buyOrder.remainMaticValue) {
                maticValue = buyOrder.remainMaticValue;
                share = (maticValue * 10 ** price_decimals) / currentPrice;
            }

            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                share,
                OrderType.BUY
            );
            IERC20Upgradeable(tokenAddress).safeTransfer(
                buyOrder.trader,
                realAmount
            );
            IERC20Upgradeable(tokenAddress).safeTransfer(treasury, feeAmount);

            buyOrder.remainQuantity -= share;
            buyOrder.remainMaticValue -= maticValue;
            buyOrder.lastTradeTimestamp = block.timestamp;

            if (buyOrder.remainQuantity == 0) {
                buyOrder.isFilled = true;
            }

            maticFilled += maticValue;
            quantityFilled += share;
        }
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
    ) external payable nonReentrant {
        require(desiredPrice > 0 && quantity > 0, "Invalid order");

        if (orderType == OrderType.BUY) {
            require(
                msg.value == (desiredPrice * quantity) / (10 ** price_decimals),
                "Incorrect MATIC sent for BUY order"
            );
        } else {
            require(msg.value == 0, "MATIC not required for sell orders");
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

        uint256 nowTime = block.timestamp;

        // Try to match with opposite orders at the same or better price
        if (orderType == OrderType.BUY) {
            // match with lowest priced sells ≤ desiredPrice
            for (
                uint256 i = activeSellOrders.length;
                i > 0 && newOrder.remainQuantity > 0;

            ) {
                Order storage sellOrder = activeSellOrders[i - 1];
                if (
                    isInvalidOrder(sellOrder) ||
                    sellOrder.desiredPrice > desiredPrice
                ) {
                    i--;
                    continue;
                }

                // Find price group
                uint256 currentPrice = sellOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 &&
                    activeSellOrders[j - 1].desiredPrice == currentPrice
                ) {
                    j--;
                }

                // Weight calc
                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order storage o = activeSellOrders[k];
                    if (!isInvalidOrder(o)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (
                    uint256 tokenFilled,
                    uint256 maticUsed
                ) = distributeBuyOrderAcrossPriceLevel(
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                newOrder.remainQuantity -= tokenFilled;
                newOrder.remainMaticValue -= maticUsed;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainQuantity > 0) {
                insertBuyLimitOrder(newOrder);
            } else {
                fullfilledOrders.push(newOrder);
            }
        } else {
            // SELL order — match with highest priced buys ≥ desiredPrice
            for (
                uint256 i = activeBuyOrders.length;
                i > 0 && newOrder.remainQuantity > 0;

            ) {
                Order storage buyOrder = activeBuyOrders[i - 1];
                if (
                    isInvalidOrder(buyOrder) ||
                    buyOrder.desiredPrice < desiredPrice
                ) {
                    i--;
                    continue;
                }

                uint256 currentPrice = buyOrder.desiredPrice;
                uint256 j = i;
                while (
                    j > 0 && activeBuyOrders[j - 1].desiredPrice == currentPrice
                ) {
                    j--;
                }

                uint256 totalWeight = 0;
                for (uint256 k = j; k < i; k++) {
                    Order storage o = activeBuyOrders[k];
                    if (!isInvalidOrder(o)) {
                        uint256 w = nowTime - o.createdAt;
                        if (w == 0) w = 1;
                        totalWeight += w;
                    }
                }

                // Time-weighted distribution
                (
                    ,
                    uint256 quantityFilled
                ) = distributeSellOrderAcrossPriceLevel(
                        newOrder,
                        currentPrice,
                        j,
                        i,
                        totalWeight,
                        nowTime
                    );

                newOrder.remainQuantity -= quantityFilled;
                // newOrder.remainMaticValue -= maticFilled;

                i = j;
            }

            // If partially filled, insert the rest
            if (newOrder.remainQuantity > 0) {
                insertSellLimitOrder(newOrder);
            } else {
                fullfilledOrders.push(newOrder);
            }
        }

        cleanLimitOrders();
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

    // We execute matched buy and sell orders one by one
    // This is called whenever new limit order is created, or can be called from backend intervally
    function executeLimitOrders() public nonReentrant {
        // clean
        cleanLimitOrders();
        require(
            activeBuyOrders.length > 0 && activeSellOrders.length > 0,
            "No Sell or Buy limit orders exist"
        );

        Order storage buyOrder = activeBuyOrders[activeBuyOrders.length - 1];
        Order storage sellOrder = activeSellOrders[activeSellOrders.length - 1];

        if (buyOrder.desiredPrice >= sellOrder.desiredPrice) {
            // we only execute orders when buy price is higher or equal than sell price
            uint256 tokenAmount = buyOrder.remainQuantity >=
                sellOrder.remainQuantity
                ? sellOrder.remainQuantity
                : buyOrder.remainQuantity;

            uint256 sellerDesiredMaticAmount = (sellOrder.desiredPrice *
                tokenAmount) / 10 ** price_decimals;
            // send matic to seller
            (uint256 realAmount, uint256 feeAmount) = getAmountDeductFee(
                sellerDesiredMaticAmount,
                OrderType.SELL
            );
            payable(sellOrder.trader).transfer(realAmount);
            payable(treasury).transfer(feeAmount);
            // decrease remain matic value
            buyOrder.remainMaticValue -= sellerDesiredMaticAmount;
            buyOrder.remainQuantity -= tokenAmount;
            buyOrder.lastTradeTimestamp = block.timestamp;

            (uint256 _realAmount, uint256 _feeAmount) = getAmountDeductFee(
                tokenAmount,
                OrderType.BUY
            );
            IERC20Upgradeable(tokenAddress).safeTransfer(
                buyOrder.trader,
                _realAmount
            );
            IERC20Upgradeable(tokenAddress).safeTransfer(treasury, _feeAmount);

            sellOrder.remainQuantity -= tokenAmount;
            sellOrder.lastTradeTimestamp = block.timestamp;

            if (buyOrder.remainQuantity == 0) {
                buyOrder.isFilled = true;
                if (buyOrder.remainMaticValue > 0) {
                    // refund
                    payable(buyOrder.trader).transfer(
                        buyOrder.remainMaticValue
                    );
                    buyOrder.remainMaticValue = 0;
                }
                // fullfilledOrders.push(buyOrder);
                removeLastFromBuyLimitOrder();
            }
            if (sellOrder.remainQuantity == 0) {
                sellOrder.isFilled = true;
                // fullfilledOrders.push(sellOrder);
                removeLastFromSellLimitOrder();
            }
        }
    }

    function isInvalidOrder(Order memory order) public view returns (bool) {
        return
            order.isCanceled ||
            order.isFilled ||
            order.timeInForce < block.timestamp ||
            order.remainQuantity == 0;
    }

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
            IERC20Upgradeable(tokenAddress).safeTransfer(
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
