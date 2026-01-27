// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PropagateToken is ERC20 {
    uint256 private constant _TOTAL_SUPPLY = 1e12 * 1e18;
    uint256 private constant _CLAIM_AMOUNT = 100 * 1e18;
    uint256 private constant _GAS_UNIT = 21000;
    uint256 private constant _TAX_DENOMINATOR = 10000;
    uint256 private constant _TAX_RATE = 1;
    uint256 private constant _PRIZE_RATE = 100;
    uint256 private constant _INITIAL_RATE = 10000;
    
    mapping(address => bool) private _claimed;
    uint256 private _airdropped;
    uint256 private _swapped;
    uint256 private _tokenPrizePool;
    uint256 private _totalBurned;
    
    event Swapped(address indexed user, uint256 pharosIn, uint256 tokensOut);
    event PrizeWon(address indexed winner, uint256 tokenPrize, uint256 pharosPrize);
    
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        uint256 deployerShare = _TOTAL_SUPPLY * 11 / 100;
        uint256 airdropShare = _TOTAL_SUPPLY * 49 / 100;
        uint256 swapShare = _TOTAL_SUPPLY - deployerShare - airdropShare;
        
        _mint(msg.sender, deployerShare);
        _mint(address(this), airdropShare + swapShare);
    }
    
    function claim() external {
        require(!_claimed[msg.sender], "Already claimed");
        require(_airdropped + _CLAIM_AMOUNT <= _TOTAL_SUPPLY * 49 / 100, "Airdrop exhausted");
        
        _claimed[msg.sender] = true;
        _airdropped += _CLAIM_AMOUNT;
        super._transfer(address(this), msg.sender, _CLAIM_AMOUNT);
    }
    
    function swap() external payable {
        require(msg.value >= tx.gasprice * _GAS_UNIT, "Insufficient gas payment");
        
        uint256 rate = getCurrentRate();
        uint256 tokensOut = msg.value * rate / 1e18;
        
        require(_swapped + tokensOut <= _TOTAL_SUPPLY * 40 / 100, "Swap pool exhausted");
        
        _swapped += tokensOut;
        super._transfer(address(this), msg.sender, tokensOut);
        
        emit Swapped(msg.sender, msg.value, tokensOut);
    }
    
    function getCurrentRate() public view returns (uint256) {
        uint256 burnedPercent = _totalBurned * 10000 / _TOTAL_SUPPLY;
        return _INITIAL_RATE * (10000 + burnedPercent) / 10000;
    }
    
    function getStats() external view returns (
        uint256 totalSupply,
        uint256 airdropped,
        uint256 swapped,
        uint256 tokenPrizePool,
        uint256 totalBurned,
        uint256 currentRate,
        uint256 contractBalance
    ) {
        return (
            _TOTAL_SUPPLY,
            _airdropped,
            _swapped,
            _tokenPrizePool,
            _totalBurned,
            getCurrentRate(),
            address(this).balance
        );
    }
    
    // 重写 transfer 函数来添加税费和抽奖逻辑
    function transfer(address to, uint256 amount) public override returns (bool) {
        address owner = _msgSender();
        uint256 tax = amount * _TAX_RATE / _TAX_DENOMINATOR;
        uint256 netAmount = amount - tax;
        
        if (tax > 0) {
            uint256 burnAmount = tax / 2;
            uint256 prizeAmount = tax - burnAmount;
            
            // 销毁
            _burn(owner, burnAmount);
            _totalBurned += burnAmount;
            
            // 奖池
            _tokenPrizePool += prizeAmount;
            super._transfer(owner, address(this), prizeAmount);
        }
        
        // 转账
        super._transfer(owner, to, netAmount);
        
        // 抽奖逻辑
        if (uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, to))) % _TAX_DENOMINATOR == 0) {
            _distributePrize(to);
        }
        
        return true;
    }
    
    // 重写 transferFrom 函数
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        
        uint256 tax = amount * _TAX_RATE / _TAX_DENOMINATOR;
        uint256 netAmount = amount - tax;
        
        if (tax > 0) {
            uint256 burnAmount = tax / 2;
            uint256 prizeAmount = tax - burnAmount;
            
            // 销毁
            _burn(from, burnAmount);
            _totalBurned += burnAmount;
            
            // 奖池
            _tokenPrizePool += prizeAmount;
            super._transfer(from, address(this), prizeAmount);
        }
        
        // 转账
        super._transfer(from, to, netAmount);
        
        // 抽奖逻辑
        if (uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, to))) % _TAX_DENOMINATOR == 0) {
            _distributePrize(to);
        }
        
        return true;
    }
    
    function _distributePrize(address winner) private {
        uint256 tokenPrize = _tokenPrizePool / _PRIZE_RATE;
        uint256 pharosPrize = address(this).balance / _PRIZE_RATE;
        
        if (tokenPrize > 0) {
            _tokenPrizePool -= tokenPrize;
            super._transfer(address(this), winner, tokenPrize);
        }
        
        if (pharosPrize > 0) {
            (bool success, ) = winner.call{value: pharosPrize}("");
            require(success, "Prize transfer failed");
        }
        
        emit PrizeWon(winner, tokenPrize, pharosPrize);
    }
    
    receive() external payable {}
}