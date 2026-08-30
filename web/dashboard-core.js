(function(root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.DashboardCore = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function() {
  'use strict';

  var DAY_MS = 24 * 60 * 60 * 1000;
  var MAX_QUOTE_AGE = 14 * DAY_MS;

  function parseNum(value) {
    if (value === '-' || value === null || value === undefined || value === '') return null;
    var number = Number.parseFloat(value);
    return Number.isFinite(number) ? number : null;
  }

  function formatPct(value) {
    if (value === null || value === undefined) return '--';
    var prefix = value > 0 ? '+' : '';
    return prefix + value.toFixed(2) + '%';
  }

  function formatMoney(value) {
    if (value === null || value === undefined) return '--';
    var absolute = Math.abs(value);
    if (absolute >= 1e8) return (value / 1e8).toFixed(2) + '亿';
    if (absolute >= 1e4) return (value / 1e4).toFixed(2) + '万';
    return value.toFixed(2) + '元';
  }

  function formatMarketCap(value) {
    if (value === null || value === undefined) return '--';
    return (value / 1e8).toFixed(0) + '亿';
  }

  function getPreviousCloseMarketCap(quote) {
    if (!quote || quote.circulatingMarketCap === null || quote.price === null || quote.prevClose === null ||
        quote.circulatingMarketCap <= 0 || quote.price <= 0 || quote.prevClose <= 0) return null;
    return quote.circulatingMarketCap / quote.price * quote.prevClose;
  }

  function calculateUnitMarketCapFundFlow(quote) {
    if (!quote || quote.fundFlow === null) return null;
    var previousCloseMarketCap = getPreviousCloseMarketCap(quote);
    if (previousCloseMarketCap === null) return null;
    // 每亿元前收盘流通市值对应的主力资金净流入，单位：万元/亿元。
    return quote.fundFlow / previousCloseMarketCap * 10000;
  }

  function formatUnitMarketCapFundFlow(value) {
    if (value === null || value === undefined) return '--';
    var prefix = value > 0 ? '+' : '';
    var number = value.toFixed(2).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
    return prefix + number + '万/亿';
  }

  function isSTStock(name) {
    return /^\*?ST/i.test(String(name || '').trim());
  }

  function isMainBoardStock(code) {
    // 沪深主板：深 000/001/002/003，沪 600/601/603/605；创业板/科创板/北交所不属于主板
    return /^(000|001|002|003|600|601|603|605)/.test(String(code || ''));
  }

  function getLimitRate(code, name) {
    var normalized = String(code || '');
    if (/^(300|301|688|689)/.test(normalized)) return 0.20;
    if (/^(4|8|920)/.test(normalized)) return 0.30;
    var stockName = String(name || '').toUpperCase();
    if (/^\*?ST/.test(stockName)) return 0.05;
    return 0.10;
  }

  function roundedLimitPrice(previousClose, rate, direction) {
    if (!Number.isFinite(previousClose) || previousClose <= 0) return null;
    return Math.round(previousClose * (1 + direction * rate) * 100 + Number.EPSILON) / 100;
  }

  function isRecentListing(quote) {
    if (!quote || !quote.listingDate || !quote.timestamp) return false;
    var text = String(quote.listingDate);
    if (!/^\d{8}$/.test(text)) return false;
    var listedAt = new Date(Number(text.slice(0, 4)), Number(text.slice(4, 6)) - 1, Number(text.slice(6, 8))).getTime();
    if (!Number.isFinite(listedAt)) return false;
    var quoteDate = new Date(quote.timestamp);
    var quoteDay = new Date(quoteDate.getFullYear(), quoteDate.getMonth(), quoteDate.getDate()).getTime();
    var age = quoteDay - listedAt;
    // 交易日历不由前端猜测；上市两周内保守视为规则未知，不计涨跌停。
    return age >= 0 && age < 14 * DAY_MS;
  }

  function getLimitStatus(quote, stock) {
    if (!quote || quote.isSuspended || quote.price === null || quote.prevClose === null) return 'none';
    if (isRecentListing(quote)) return 'unknown';
    var rate = getLimitRate(stock && stock.code ? stock.code : quote.code, stock && stock.name ? stock.name : quote.name);
    var upper = roundedLimitPrice(quote.prevClose, rate, 1);
    var lower = roundedLimitPrice(quote.prevClose, rate, -1);
    if (upper !== null && Math.abs(quote.price - upper) < 0.005) return 'up';
    if (lower !== null && Math.abs(quote.price - lower) < 0.005) return 'down';
    return 'none';
  }

  function isQuoteValid(quote, now) {
    if (!quote || quote.isSuspended || quote.price === null || quote.changePct === null) return false;
    if (!quote.timestamp) return true;
    return (now || Date.now()) - quote.timestamp <= MAX_QUOTE_AGE;
  }

  function getPoolMetrics(pool, quotes, now) {
    var stocks = pool && Array.isArray(pool.stocks) ? pool.stocks : [];
    var empty = {
      avgChange: null,
      limitUp: 0,
      limitDown: 0,
      limitUnknown: 0,
      total: stocks.length,
      capitalInflow: null,
      unitMarketCapFundFlow: null,
      redRate: null,
      missingFund: stocks.length,
      fundValidCount: 0,
      validCount: 0
    };
    if (!stocks.length) return empty;

    var totalChange = 0;
    var validCount = 0;
    var limitUp = 0;
    var limitDown = 0;
    var limitUnknown = 0;
    var capitalInflow = 0;
    var fundValidCount = 0;
    var redCount = 0;
    var validFundFlow = 0;
    var previousCloseMarketCap = 0;
    var unitMarketCapValidCount = 0;

    for (var index = 0; index < stocks.length; index++) {
      var stock = stocks[index];
      var quote = quotes ? quotes[stock.secid] : null;
      if (!isQuoteValid(quote, now)) continue;

      totalChange += quote.changePct;
      validCount++;
      if (quote.changePct > 0) redCount++;

      var limitStatus = getLimitStatus(quote, stock);
      if (limitStatus === 'up') limitUp++;
      else if (limitStatus === 'down') limitDown++;
      else if (limitStatus === 'unknown') limitUnknown++;

      if (quote.fundFlow !== null) {
        capitalInflow += quote.fundFlow;
        fundValidCount++;
      }
      var stockPreviousCloseMarketCap = getPreviousCloseMarketCap(quote);
      if (quote.fundFlow !== null && stockPreviousCloseMarketCap !== null) {
        validFundFlow += quote.fundFlow;
        previousCloseMarketCap += stockPreviousCloseMarketCap;
        unitMarketCapValidCount++;
      }
    }

    return {
      avgChange: validCount > 0 ? totalChange / validCount : null,
      limitUp: limitUp,
      limitDown: limitDown,
      limitUnknown: limitUnknown,
      total: stocks.length,
      capitalInflow: fundValidCount > 0 ? capitalInflow : null,
      unitMarketCapFundFlow: unitMarketCapValidCount > 0 ? validFundFlow / previousCloseMarketCap * 10000 : null,
      redRate: validCount > 0 ? redCount / validCount * 100 : null,
      missingFund: stocks.length - fundValidCount,
      fundValidCount: fundValidCount,
      validCount: validCount
    };
  }

  function sameLocalDay(first, second) {
    var a = new Date(first);
    var b = new Date(second);
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  }

  function clockValue(date) {
    return date.getHours() * 100 + date.getMinutes();
  }

  function isPollingWindow(timestamp) {
    var date = new Date(timestamp || Date.now());
    var day = date.getDay();
    if (day === 0 || day === 6) return false;
    var value = clockValue(date);
    return (value >= 925 && value <= 1135) || (value >= 1255 && value <= 1505);
  }

  function getMarketPhase(nowTimestamp, marketTimestamp, staleThreshold) {
    var now = new Date(nowTimestamp || Date.now());
    var day = now.getDay();
    var value = clockValue(now);
    var weekday = day !== 0 && day !== 6;
    var morning = value >= 930 && value <= 1130;
    var afternoon = value >= 1300 && value <= 1500;
    var inSession = weekday && (morning || afternoon);

    if (inSession) {
      if (!marketTimestamp || !sameLocalDay(now.getTime(), marketTimestamp)) return 'waiting';
      return now.getTime() - marketTimestamp > (staleThreshold || 30000) ? 'delayed' : 'trading';
    }
    if (weekday && value < 930) return 'preopen';
    if (weekday && value > 1130 && value < 1300) return 'lunch';
    return weekday && value > 1500 ? 'closed' : 'holiday';
  }

  return {
    DAY_MS: DAY_MS,
    MAX_QUOTE_AGE: MAX_QUOTE_AGE,
    parseNum: parseNum,
    formatPct: formatPct,
    formatMoney: formatMoney,
    formatMarketCap: formatMarketCap,
    formatUnitMarketCapFundFlow: formatUnitMarketCapFundFlow,
    getPreviousCloseMarketCap: getPreviousCloseMarketCap,
    calculateUnitMarketCapFundFlow: calculateUnitMarketCapFundFlow,
    isSTStock: isSTStock,
    isMainBoardStock: isMainBoardStock,
    getLimitRate: getLimitRate,
    roundedLimitPrice: roundedLimitPrice,
    getLimitStatus: getLimitStatus,
    isQuoteValid: isQuoteValid,
    getPoolMetrics: getPoolMetrics,
    isPollingWindow: isPollingWindow,
    getMarketPhase: getMarketPhase
  };
});
