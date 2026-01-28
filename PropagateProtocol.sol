// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PropagateToken is ERC20, Ownable {
    // 总供应量：1万亿（1,000,000,000,000）带18位小数
    uint256 private constant TOTAL_SUPPLY_TOKENS = 1e12 * 1e18; // 1,000,000,000,000 * 10^18
    
    // 固定兑换率：1 MON = 10,000 PPT
    uint256 private constant FIXED_RATE = 10000;
    
    // 税费设置 - 调整为0.01%
    uint256 private constant TAX_DENOMINATOR = 100000; // 100% = 100000 (增加分母精度)
    uint256 private constant TAX_RATE = 10;             // 0.01% = 10/100000
    uint256 private constant BURN_RATE = 50;            // 50% of tax for burn (0.005%)
    uint256 private constant PRIZE_POOL_RATE = 50;      // 50% of tax for prize pool (0.005%)
    
    // 奖池抽奖设置
    uint256 private constant PRIZE_CHANCE_DENOMINATOR = 10000; // 0.01% 中奖概率
    uint256 private constant PRIZE_WIN_RATE = 100;             // 1% of pool to winner
    
    // 状态变量
    uint256 public totalSwapped;        // 已兑换总量
    uint256 public tokenPrizePool;      // PPT奖池
    uint256 public totalBurned;         // 总销毁量
    uint256 public totalTransfers;      // 总转账次数
    uint256 public lastPrizeTime;       // 上次中奖时间
    
    // 避免在构造函数中多次计算，使用immutable
    uint256 private immutable maxSwapPool;
    uint256 private immutable swapPoolLimit;
    uint256 private immutable deployerShare;
    uint256 private immutable marketingShare;
    
    // 事件
    event Swapped(address indexed user, uint256 monAmount, uint256 pptAmount);
    event PrizeWon(address indexed winner, uint256 tokenPrize, uint256 monPrize);
    event TokensBurned(uint256 amount);
    event DonationReceived(address donor, uint256 amount, bool isMon);
    
    // 构造函数 - 初始化代币
    constructor() ERC20("Propagate Protocol Token", "PPT") Ownable(msg.sender) {
        // 预先计算不变的值，节省gas
        deployerShare = TOTAL_SUPPLY_TOKENS * 11 / 100;
        marketingShare = TOTAL_SUPPLY_TOKENS * 49 / 100;
        
        // 合约保留 40% (400B PPT) 用于兑换池
        uint256 swapPoolShare = TOTAL_SUPPLY_TOKENS - deployerShare - marketingShare;
        
        // 预先计算兑换池限制
        maxSwapPool = TOTAL_SUPPLY_TOKENS * 40 / 100;
        swapPoolLimit = maxSwapPool * 95 / 100; // 95% of swap pool
        
        // 铸造代币 - 使用批量铸造减少gas
        _mintBatch(msg.sender, deployerShare + marketingShare);
        _mint(address(this), swapPoolShare);
        
        // 记录初始状态
        totalSwapped = 0;
        tokenPrizePool = 0;
        totalBurned = 0;
        totalTransfers = 0;
        lastPrizeTime = block.timestamp;
    }
    
    // 批量铸造内部函数，减少gas
    function _mintBatch(address to, uint256 amount) internal {
        _mint(to, amount);
    }
    
    // 兑换函数 - 用户发送MON，接收PPT
    function swap() external payable {
        require(msg.value > 0, "Must send MON to swap");
        require(msg.value >= 0.001 ether, "Minimum swap is 0.001 MON");
        
        // 计算应得的PPT数量
        uint256 pptAmount = msg.value * FIXED_RATE; // 1 MON = 10000 PPT
        
        // 检查合约是否有足够的PPT余额
        uint256 contractPPTBalance = balanceOf(address(this));
        require(contractPPTBalance >= pptAmount, "Insufficient PPT in swap pool");
        
        // 检查是否超过兑换池限制（使用预先计算的值）
        require(totalSwapped + pptAmount <= swapPoolLimit, "Swap pool limit reached");
        
        // 更新状态
        totalSwapped += pptAmount;
        
        // 直接从合约转账给用户，避免中间状态
        _transfer(address(this), msg.sender, pptAmount);
        
        // 发射事件
        emit Swapped(msg.sender, msg.value, pptAmount);
    }
    
    // 优化的transfer函数 - 添加税费和抽奖逻辑
    function transfer(address to, uint256 amount) public override returns (bool) {
        address sender = _msgSender();
        
        // 检查发送者余额
        require(balanceOf(sender) >= amount, "Insufficient PPT balance");
        
        // 计算税费（0.01%）
        uint256 taxAmount = (amount * TAX_RATE) / TAX_DENOMINATOR;
        uint256 netAmount = amount - taxAmount;
        
        if (taxAmount > 0) {
            // 0.01% 税费分配：50%销毁，50%奖池
            uint256 burnAmount = (taxAmount * BURN_RATE) / 100; // 使用100作为分母，因为BURN_RATE是百分比
            uint256 prizeAmount = taxAmount - burnAmount;
            
            // 执行销毁
            if (burnAmount > 0) {
                _burn(sender, burnAmount);
                totalBurned += burnAmount;
                emit TokensBurned(burnAmount);
            }
            
            // 增加奖池 - 直接转账到合约
            if (prizeAmount > 0) {
                _transfer(sender, address(this), prizeAmount);
                tokenPrizePool += prizeAmount;
            }
        }
        
        // 转账净额给接收者
        _transfer(sender, to, netAmount);
        
        // 更新转账计数
        totalTransfers++;
        
        // 抽奖逻辑 - 0.01% 中奖概率，使用优化的随机数生成
        if (shouldDistributePrize(to)) {
            _distributePrize(to);
        }
        
        return true;
    }
    
    // 优化的transferFrom函数
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        
        // 使用OpenZeppelin的_spendAllowance，它已经优化
        _spendAllowance(from, spender, amount);
        
        // 检查发送者余额
        require(balanceOf(from) >= amount, "Insufficient PPT balance");
        
        // 计算税费（0.01%）
        uint256 taxAmount = (amount * TAX_RATE) / TAX_DENOMINATOR;
        uint256 netAmount = amount - taxAmount;
        
        if (taxAmount > 0) {
            // 0.01% 税费分配
            uint256 burnAmount = (taxAmount * BURN_RATE) / 100;
            uint256 prizeAmount = taxAmount - burnAmount;
            
            // 执行销毁
            if (burnAmount > 0) {
                _burn(from, burnAmount);
                totalBurned += burnAmount;
                emit TokensBurned(burnAmount);
            }
            
            // 增加奖池
            if (prizeAmount > 0) {
                _transfer(from, address(this), prizeAmount);
                tokenPrizePool += prizeAmount;
            }
        }
        
        // 转账净额给接收者
        _transfer(from, to, netAmount);
        
        // 更新转账计数
        totalTransfers++;
        
        // 抽奖逻辑
        if (shouldDistributePrize(to)) {
            _distributePrize(to);
        }
        
        return true;
    }
    
    // 检查是否应该分发奖池 - 优化版
    function shouldDistributePrize(address to) private view returns (bool) {
        // 确保有奖池余额
        if (tokenPrizePool == 0) return false;
        
        // 确保至少1小时没有中奖
        if (block.timestamp - lastPrizeTime < 1 hours) return false;
        
        // 0.01% 中奖概率 - 使用更高效的随机数生成
        // 使用 block.prevrandao 替代已弃用的 block.difficulty
        uint256 random = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            to
        )));
        
        return (random % PRIZE_CHANCE_DENOMINATOR == 0);
    }
    
    // 分发奖池奖励 - 优化版
    function _distributePrize(address winner) private {
        // 计算奖励：1% 的PPT奖池和1% 的MON奖池
        uint256 pptPrize = (tokenPrizePool * PRIZE_WIN_RATE) / TAX_DENOMINATOR;
        uint256 monPrize = (address(this).balance * PRIZE_WIN_RATE) / TAX_DENOMINATOR;
        
        // 确保有奖励可分发
        require(pptPrize > 0 || monPrize > 0, "No prize to distribute");
        
        // 分发PPT奖励
        if (pptPrize > 0 && pptPrize <= tokenPrizePool) {
            // 使用unchecked减少gas，因为我们已经检查了pptPrize <= tokenPrizePool
            unchecked {
                tokenPrizePool -= pptPrize;
            }
            _transfer(address(this), winner, pptPrize);
        }
        
        // 分发MON奖励 - 使用call的简化形式
        if (monPrize > 0 && monPrize <= address(this).balance) {
            (bool success, ) = winner.call{value: monPrize}("");
            require(success, "MON prize transfer failed");
        }
        
        // 更新最后中奖时间
        lastPrizeTime = block.timestamp;
        
        // 发射事件
        emit PrizeWon(winner, pptPrize, monPrize);
    }
    
    // 获取合约统计数据 - 优化版
    function getStats() external view returns (
        uint256 totalSupply,
        uint256 swapped,
        uint256 tokenPrizePoolAmount,
        uint256 burned,
        uint256 currentRate,
        uint256 contractMonBalance,
        uint256 contractPptBalance,
        uint256 transfersCount
    ) {
        return (
            TOTAL_SUPPLY_TOKENS,
            totalSwapped,
            tokenPrizePool,
            totalBurned,
            FIXED_RATE,
            address(this).balance,
            balanceOf(address(this)),
            totalTransfers
        );
    }
    
    // 获取当前兑换率（固定）
    function getCurrentRate() public pure returns (uint256) {
        return FIXED_RATE;
    }
    
    // 获取合约剩余可兑换的PPT数量
    function getRemainingSwapPool() public view returns (uint256) {
        if (totalSwapped >= swapPoolLimit) {
            return 0;
        }
        return swapPoolLimit - totalSwapped;
    }
    
    // 获取当前中奖概率信息
    function getPrizeInfo() external view returns (
        uint256 prizePoolPPT,
        uint256 prizePoolMON,
        uint256 chancePercent,
        uint256 timeSinceLastPrize
    ) {
        return (
            tokenPrizePool,
            address(this).balance,
            PRIZE_CHANCE_DENOMINATOR, // 返回分母，前端计算概率
            block.timestamp - lastPrizeTime
        );
    }
    
    // 获取当前税费信息
    function getTaxInfo() external pure returns (
        uint256 taxRate,
        uint256 burnRate,
        uint256 prizePoolRate,
        uint256 taxDenominator
    ) {
        return (
            TAX_RATE,
            BURN_RATE,
            PRIZE_POOL_RATE,
            TAX_DENOMINATOR
        );
    }
    
    // 所有者可以提取合约中的MON（用于项目发展）
    function withdrawMon(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient MON balance");
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Withdrawal failed");
    }
    
    // 所有者可以提取合约中多余的PPT（如果合约意外收到PPT）
    function withdrawPpt(uint256 amount) external onlyOwner {
        uint256 contractBalance = balanceOf(address(this));
        // 确保不会提取兑换池的PPT
        uint256 swapPoolBalance = getRemainingSwapPool() + (maxSwapPool * 5 / 100); // 包括缓冲的5%
        uint256 withdrawable = contractBalance > swapPoolBalance ? contractBalance - swapPoolBalance : 0;
        
        require(amount <= withdrawable, "Cannot withdraw from swap pool");
        _transfer(address(this), owner(), amount);
    }
    
    // 捐赠函数 - 用户可以直接捐赠MON到奖池
    function donateMon() external payable {
        require(msg.value > 0, "Must send MON to donate");
        emit DonationReceived(msg.sender, msg.value, true);
    }
    
    // 接收MON的fallback函数
    receive() external payable {
        // 默认视为捐赠
        emit DonationReceived(msg.sender, msg.value, true);
    }
    
    // 批量转账函数，减少gas成本（可选功能）
    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts) external returns (bool) {
        require(recipients.length == amounts.length, "Arrays length mismatch");
        require(recipients.length <= 100, "Too many recipients");
        
        address sender = _msgSender();
        uint256 totalAmount = 0;
        
        // 计算总金额
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        // 检查余额
        require(balanceOf(sender) >= totalAmount, "Insufficient PPT balance");
        
        // 计算总税费
        uint256 totalTax = (totalAmount * TAX_RATE) / TAX_DENOMINATOR;
        uint256 netTotalAmount = totalAmount - totalTax;
        
        // 计算税费分配
        uint256 burnAmount = (totalTax * BURN_RATE) / 100;
        uint256 prizeAmount = totalTax - burnAmount;
        
        // 执行销毁
        if (burnAmount > 0) {
            _burn(sender, burnAmount);
            totalBurned += burnAmount;
            emit TokensBurned(burnAmount);
        }
        
        // 增加奖池
        if (prizeAmount > 0) {
            _transfer(sender, address(this), prizeAmount);
            tokenPrizePool += prizeAmount;
        }
        
        // 批量转账（按比例分配税费）
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 netAmount = (amounts[i] * netTotalAmount) / totalAmount;
            _transfer(sender, recipients[i], netAmount);
        }
        
        // 更新转账计数（只算一次转账）
        totalTransfers++;
        
        return true;
    }
    
    // 获取合约版本信息
    function getVersion() external pure returns (string memory) {
        return "PropagateToken v2.0 - Optimized";
    }
}