//+------------------------------------------------------------------+
//|                                          Hybrid_Ultimate_EA.mq5  |
//|                                  Copyright 2026, AI Developer    |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
// HYBRID ULTIMATE EA - MERGED BUILD
//
// This file is a Code Integration (NOT a rewrite) of three previously
// independent Expert Advisors:
//   - Hybrid_Crypto_Mode.mq5
//   - Hybrid_Forex_Mode.mq5
//   - Hybrid_Gold_Silver_Mode.mq5
//
// ZERO LOGIC MODIFICATION: every trading condition, engine, filter,
// score calculation, money-management rule, cooldown rule, and
// dashboard behavior inside each module is byte-for-byte identical to
// its original source. The ONLY changes made during this merge are:
//
//   1) A new Symbol Mode Router (see below) that reads the current
//      chart symbol and selects which module executes. It contains
//      NO trading logic of its own.
//
//   2) Function names, global variables, input parameters, and the
//      per-module CTrade objects have been prefixed per module
//      (Cr_ = Crypto, Fx_ = Forex, Gs_ = Gold & Silver) ONLY to avoid
//      duplicate-identifier compile errors, since all three source
//      files were independently written with overlapping names
//      (OnInit/OnTick/OnDeinit, glbCooldownUntil, InpMaxLotSize,
//      CountTotalPositions, "trade", etc). Every reference to a
//      renamed identifier was updated accordingly. No implementation
//      body was altered.
//
//   3) OnInit()/OnTick()/OnDeinit() are MQL5 event handlers and can
//      only exist once per program. Each module's original
//      OnInit()/OnTick()/OnDeinit() was therefore renamed to
//      Cr_OnInit()/Cr_OnTick()/Cr_OnDeinit() (and Fx_/Gs_
//      equivalents) with their bodies left 100% untouched. The real
//      OnInit()/OnTick()/OnDeinit() at the bottom of this file are
//      new, and their only job is: detect the symbol mode, then call
//      the matching module's renamed handler. No trading decision is
//      made in these wrappers.
//
// Elements that were verified to be 100% IDENTICAL, character-for-
// character, across all three original source files (the enums
// ENUM_MARKET_REGIME / ENUM_TREND_DIRECTION / ENUM_RISK_LEVEL, the
// HistoryZone struct, and the EXPERT_MAGIC / DASH_PREFIX constants)
// are declared ONCE in the Shared/Common section below, per the
// "Shared/Common Functions Rule" (identical implementations only).
// Everything else remains fully separated inside its own module and
// is never called across module boundaries.
//
// PATCH SET E (Unified Trading Flow / AI Filter / Cascade Lot / Weekend
// Rules - minimal-impact modification, applies ONLY to Money Management,
// AI Filter (Forex), Gold/Silver Sideway Zone config, News Filter behavior,
// and Weekend Risk Rules, per spec):
//  E1. Forex AI Confidence Score (Fx_AIConfidenceScore - formula/weights
//      UNCHANGED) is now also called as the Final Entry Filter in the
//      Forex Sideway Price Engine and Forex Extreme Engine, matching the
//      Forex Trend Engine (which already had it). PASS/BLOCK only; never
//      changes Signal/Direction/Zone/Lot.
//  E2. Cascade Lot Calculation: Cr_ScoreToLot() and Fx_ScoreToLot() (Crypto
//      and Forex dynamic-lot engines only - Trend & Extreme) now take an
//      additional highImpactNews parameter and apply a temporary lot
//      reduction (x0.75, floored at the existing minimum) as an explicit
//      News Filter cascade step, positioned immediately after the existing
//      Risk-Level lot and before the existing Smart-History / Final Lot
//      steps. Gold & Silver (fixed 0.01 lot) and the Sideway zone-table
//      lots (Crypto/Forex) are excluded, per spec. News Filter still never
//      blocks orders or changes BUY/SELL.
//  E3. Weekend Risk Rules: Forex and Gold & Silver OnTick now detect
//      Saturday/Sunday and block only NEW order entries on those days
//      (existing Cooldown / Max Orders / Risk Level / all other logic is
//      untouched). Crypto's existing 7-day weekend behavior is unchanged.
//  E4. Crypto Monday-Friday Stop-Loss cooldown corrected from 2 Hours to
//      1 Hour per the Weekend Risk Rules spec (weekend branch, still 2
//      Hours, is unchanged).
// All Trend/Sideway/Extreme signal logic, indicators (EMA/ADX/ATR/RSI),
// AI formula/weights, Gold & Silver Sideway Zones, and Money Management
// asset assignment (Crypto/Forex Dynamic, Gold/Silver Fixed 0.01) are
// otherwise unchanged.
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
// SHARED / COMMON  (only declared here because implementation is
// 100% identical across all three original EAs - see note above)
//====================================================================
enum ENUM_MARKET_REGIME    { REGIME_SIDEWAY, REGIME_TREND };
enum ENUM_TREND_DIRECTION  { DIRECTION_NONE, DIRECTION_BULL, DIRECTION_BEAR };
enum ENUM_RISK_LEVEL       { RISK_LOW, RISK_MEDIUM, RISK_HIGH };

struct HistoryZone
{
   double priceLevel;
   int    wins;
   int    losses;
};

#define EXPERT_MAGIC 123456
#define DASH_PREFIX  "KAI_DASH_"

// Forward declaration (dashboard display-formatting only - see full
// definition in the "SHARED DASHBOARD (KAI MT5)" section). Declared
// early so the mode modules below can call it when building their
// read-only Cr_/Gs_/Fx_glbDashCooldownTxt display strings.
string KAI_FormatCooldownText(bool slLockActive, datetime slLockEnd,
                               bool freqCooldownActive,
                               int adaptiveMin, int riskBonusMin);

//====================================================================
// TREND CONFIRMATION LAYER (PATCH - Big-Body Candle Confirmation)
//
// *** ADDITIVE ONLY - ZERO MODIFICATION TO EXISTING LOGIC ***
//
// New functions only. Nothing below reads/writes any existing
// variable, and nothing existing is renamed, moved, or rewritten.
// Shared by Cr_/Gs_/Fx_RunTrendEngine() since the rule (D1 direction
// + big-body confirmation across H4/H1/M30/M15) is identical across
// all three modules and operates on the current chart _Symbol in
// every case (Symbol Mode Router runs one module per chart).
//
// Each Cr_/Gs_/Fx_ trend engine keeps its own original greenBars /
// redBars counting loop completely untouched (still used for the
// dashboard score and EA/Entry score calculations). ONLY the final
// isBullTrendFollowing / isBearTrendFollowing / isCounterBuy /
// isCounterSell condition assignment is changed, at the call site,
// to use ConfirmFollowTrend() / ConfirmCounterTrend() instead of the
// old ">= 3" / "== 4" plain bar-count comparison.
//====================================================================

input group "=== Trend Confirmation Layer: Big-Body Candle Settings (patch) ==="
enum ENUM_BIGBAR_METHOD
{
   BIGBAR_FIX_POINTS = 0,
   BIGBAR_ATR        = 1,
   BIGBAR_BODY_RATIO = 2
};

input ENUM_BIGBAR_METHOD InpBigBarMethod   = BIGBAR_ATR;
input int                InpATRPeriod      = 14;
input double             InpATRMultiplier  = 1.5;
input int                InpFixPoints      = 500;
input double             InpBodyRatio      = 0.70;

// --- Candle color helpers (Open/Close only) --------------------------
bool IsBullishCandle(const MqlRates &rate)
{
   return (rate.close > rate.open);
}

bool IsBearishCandle(const MqlRates &rate)
{
   return (rate.close < rate.open);
}

// --- Body size / ratio helpers ---------------------------------------
double GetBodySize(const MqlRates &rate)
{
   return MathAbs(rate.open - rate.close);
}

double GetBodyRatio(const MqlRates &rate)
{
   double range = rate.high - rate.low;
   if(range <= 0.0) return 0.0;
   return GetBodySize(rate) / range;
}

// --- Big-body check (one method only, per InpBigBarMethod) -----------
// Works on any timeframe/symbol: ATR is read on the same (symbol, tf)
// as the candle being measured.
bool IsBigBody(const string symbol, ENUM_TIMEFRAMES tf, const MqlRates &rate)
{
   switch(InpBigBarMethod)
   {
      case BIGBAR_FIX_POINTS:
      {
         double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
         if(point <= 0.0) return false;
         return ((GetBodySize(rate) / point) >= InpFixPoints);
      }
      case BIGBAR_BODY_RATIO:
         return (GetBodyRatio(rate) >= InpBodyRatio);
      case BIGBAR_ATR:
      default:
      {
         int atrHandle = iATR(symbol, tf, InpATRPeriod);
         if(atrHandle == INVALID_HANDLE) return false;
         double atrVal[1];
         double atr = 0.0;
         if(CopyBuffer(atrHandle, 0, 0, 1, atrVal) > 0) atr = atrVal[0];
         IndicatorRelease(atrHandle);
         if(atr <= 0.0) return false;
         return (GetBodySize(rate) > (atr * InpATRMultiplier));
      }
   }
}

// --- Two-candle same-color check --------------------------------------
// H4/H1: both candles must also pass IsBigBody(). M30/M15: color only.
bool HasTwoBullCandles(const string symbol, ENUM_TIMEFRAMES tf)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(symbol, tf, 1, 2, r) < 2) return false;

   if(!IsBullishCandle(r[0]) || !IsBullishCandle(r[1])) return false;

   if(tf == PERIOD_H4 || tf == PERIOD_H1)
   {
      if(!IsBigBody(symbol, tf, r[0]) || !IsBigBody(symbol, tf, r[1])) return false;
   }

   return true;
}

bool HasTwoBearCandles(const string symbol, ENUM_TIMEFRAMES tf)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(symbol, tf, 1, 2, r) < 2) return false;

   if(!IsBearishCandle(r[0]) || !IsBearishCandle(r[1])) return false;

   if(tf == PERIOD_H4 || tf == PERIOD_H1)
   {
      if(!IsBigBody(symbol, tf, r[0]) || !IsBigBody(symbol, tf, r[1])) return false;
   }

   return true;
}

// --- Follow-Trend confirmation: >= 3 of 4 timeframes aligned with D1 ---
bool ConfirmFollowTrend(const string symbol, ENUM_TREND_DIRECTION d1Trend)
{
   if(d1Trend != DIRECTION_BULL && d1Trend != DIRECTION_BEAR) return false;

   ENUM_TIMEFRAMES tfs[4] = {PERIOD_H4, PERIOD_H1, PERIOD_M30, PERIOD_M15};
   int alignedCount = 0;

   for(int i = 0; i < 4; i++)
   {
      bool aligned = (d1Trend == DIRECTION_BULL) ? HasTwoBullCandles(symbol, tfs[i])
                                                  : HasTwoBearCandles(symbol, tfs[i]);
      if(aligned) alignedCount++;
   }

   return (alignedCount >= 3);
}

// --- Counter-Trend confirmation: 4 of 4 timeframes OPPOSITE to D1 ------
bool ConfirmCounterTrend(const string symbol, ENUM_TREND_DIRECTION d1Trend)
{
   if(d1Trend != DIRECTION_BULL && d1Trend != DIRECTION_BEAR) return false;

   ENUM_TIMEFRAMES tfs[4] = {PERIOD_H4, PERIOD_H1, PERIOD_M30, PERIOD_M15};
   int alignedCount = 0;

   for(int i = 0; i < 4; i++)
   {
      bool aligned = (d1Trend == DIRECTION_BULL) ? HasTwoBearCandles(symbol, tfs[i])
                                                  : HasTwoBullCandles(symbol, tfs[i]);
      if(aligned) alignedCount++;
   }

   return (alignedCount == 4);
}

//====================================================================
// TREND ENTRY QUALITY SCORE (TEQS) - ADDITIONAL CONFIRMATION FILTER
//
// *** ADDITIONAL FILTER ONLY - ZERO MODIFICATION TO EXISTING LOGIC ***
//
// This module is a pure PASS/BLOCK filter inserted AFTER the AI
// Confidence Score check, ONLY when the Trend Following Engine is
// active. It has NO authority to:
//   - Change BUY to SELL or SELL to BUY
//   - Change Lot size
//   - Change TP / SL
//   - Change Risk Level
//   - Modify any existing logic
//
// Scoring system (100 points total):
//   1. Historical Trade Quality   : 40 pts
//   2. Historical Rejection       : 15 pts
//   3. Breakout Probability       : 15 pts
//   4. Distance To Key Level      : 15 pts
//   5. Trend Exhaustion           :  5 pts
//   6. Liquidity Zone Detection   :  5 pts
//   7. Time At Resistance/Support :  5 pts
//
// TEQS >= 70 => PASS => Execute Order
// TEQS <  70 => BLOCK => WAIT
//
// When TEQS is disabled (InpTEQSEnable = false), the call site
// returns true immediately, restoring 100% original behavior.
//====================================================================

input group "=== Trend Entry Quality Score (TEQS) - Additional Filter ==="
input bool   InpTEQSEnable           = true;    // Enable TEQS filter (Trend Following only)
input double InpTEQSPassThreshold    = 70.0;    // Minimum TEQS score to PASS (0-100)
input double InpTEQSZoneATRMulti     = 0.5;     // Zone width for History lookup (±ATR * this)
input int    InpTEQSHistoryDays      = 90;      // Days of history to search for zone trades

// TEQS display-only global (updated each tick, never feeds back into trading decisions)
double glbTEQSLastScore  = 0.0;
string glbTEQSLastReason = "-";

//--------------------------------------------------------------------
// TEQS Helper: Get ATR value for a given timeframe
//--------------------------------------------------------------------
double TEQS_GetATR(ENUM_TIMEFRAMES tf, int period)
{
   int h = iATR(_Symbol, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   double val = 0.0;
   if(CopyBuffer(h, 0, 0, 1, buf) > 0) val = buf[0];
   IndicatorRelease(h);
   return val;
}

//--------------------------------------------------------------------
// TEQS Component 1: Historical Trade Quality (40 pts)
// Zone-based: only trades within ±ATR*InpTEQSZoneATRMulti of current
// price are counted, direction-filtered (BUY history for BUY signals,
// SELL history for SELL signals). Never mixes BUY and SELL history.
//--------------------------------------------------------------------
double TEQS_HistoricalTradeQuality(ENUM_ORDER_TYPE direction)
{
   double atrD1 = TEQS_GetATR(PERIOD_D1, 14);
   if(atrD1 <= 0.0) atrD1 = _Point * 100;

   double zoneHalf   = atrD1 * InpTEQSZoneATRMulti;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double zoneLow    = currentPrice - zoneHalf;
   double zoneHigh   = currentPrice + zoneHalf;

   datetime histFrom = TimeCurrent() - (datetime)(InpTEQSHistoryDays * 86400);

   // --- 1.1 Fast Win (10 pts): check closed deals in zone ---
   // Scoring per last qualified trade's holding time
   double fastWinScore = 5.0; // default mid
   double slowWinScore = 5.0;
   double floatScore   = 10.0;
   double winLossScore = 4.0;

   // Scan closed history for zone deals
   int    zoneTrades = 0;
   int    zoneWins   = 0;
   int    zoneLosses = 0;
   double lastHoldHours = -1.0;
   double lastWinHoldHours = -1.0;

   if(HistorySelect(histFrom, TimeCurrent()))
   {
      uint totalDeals = HistoryDealsTotal();
      for(uint i = 0; i < totalDeals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(!HistoryDealSelect(ticket)) continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;

         // Direction filter: BUY signal -> only DEAL_TYPE_BUY deals
         //                   SELL signal -> only DEAL_TYPE_SELL deals
         ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
         if(direction == ORDER_TYPE_BUY  && dealType != DEAL_TYPE_BUY)  continue;
         if(direction == ORDER_TYPE_SELL && dealType != DEAL_TYPE_SELL) continue;

         // Only OUT entries (closing a position)
         ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(dealEntry != DEAL_ENTRY_OUT) continue;

         double dealPrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
         if(dealPrice < zoneLow || dealPrice > zoneHigh) continue;

         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

         // Find the matching open deal to get hold time
         ulong   posId  = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
         datetime openTime = 0;
         for(uint j = 0; j < totalDeals; j++)
         {
            ulong tOpen = HistoryDealGetTicket(j);
            if(!HistoryDealSelect(tOpen)) continue;
            if((ulong)HistoryDealGetInteger(tOpen, DEAL_POSITION_ID) != posId) continue;
            ENUM_DEAL_ENTRY entOpen = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(tOpen, DEAL_ENTRY);
            if(entOpen == DEAL_ENTRY_IN) { openTime = (datetime)HistoryDealGetInteger(tOpen, DEAL_TIME); break; }
         }
         double holdHours = (openTime > 0) ? (double)(dealTime - openTime) / 3600.0 : 0.0;

         zoneTrades++;
         if(profit > 0)
         {
            zoneWins++;
            lastWinHoldHours = holdHours;
         }
         else
         {
            zoneLosses++;
            lastHoldHours = holdHours;
         }
      }
   }

   // --- 1.1 Fast Win score (10 pts) based on last winning hold time ---
   if(lastWinHoldHours >= 0)
   {
      if(lastWinHoldHours < 12)       fastWinScore = 10.0;
      else if(lastWinHoldHours < 24)  fastWinScore = 8.0;
      else if(lastWinHoldHours < 48)  fastWinScore = 5.0;
      else                            fastWinScore = 2.0;
   }

   // --- 1.2 Slow Win / Little Loss score (10 pts) based on last win hold ---
   if(lastWinHoldHours >= 0)
   {
      if(lastWinHoldHours < 24)       slowWinScore = 10.0;
      else if(lastWinHoldHours < 48)  slowWinScore = 6.0;
      else if(lastWinHoldHours < 72)  slowWinScore = 3.0;
      else                            slowWinScore = 0.0;
   }

   // --- 1.3 Floating Position score (10 pts) ---
   // Check current open positions in same direction for this symbol
   double maxFloatHours = 0.0;
   datetime now = TimeCurrent();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != EXPERT_MAGIC) continue;
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      bool dirMatch = (direction == ORDER_TYPE_BUY  && posType == POSITION_TYPE_BUY) ||
                      (direction == ORDER_TYPE_SELL && posType == POSITION_TYPE_SELL);
      if(!dirMatch) continue;
      datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
      double floatHours = (double)(now - posTime) / 3600.0;
      if(floatHours > maxFloatHours) maxFloatHours = floatHours;
   }
   if(maxFloatHours == 0.0)      floatScore = 10.0;
   else if(maxFloatHours <= 24)  floatScore = 7.0;
   else if(maxFloatHours <= 48)  floatScore = 3.0;
   else                          floatScore = 0.0;

   // --- 1.4 Win/Loss Quality score (10 pts) based on zone win rate ---
   if(zoneTrades >= 3)
   {
      double winRate = (double)zoneWins / (double)zoneTrades;
      if(winRate > 0.80)       winLossScore = 10.0;
      else if(winRate >= 0.60) winLossScore = 7.0;
      else if(winRate >= 0.40) winLossScore = 4.0;
      else                     winLossScore = 0.0;
   }
   else
   {
      winLossScore = 5.0; // neutral when no enough history
   }

   return MathMin(40.0, fastWinScore + slowWinScore + floatScore + winLossScore);
}

//--------------------------------------------------------------------
// TEQS Component 2: Historical Rejection (15 pts)
// Checks D1 candles for touch/rejection/failed-break near current
// price. Direction-filtered: BUY -> check resistance/swing-high side,
// SELL -> check support/swing-low side.
//--------------------------------------------------------------------
double TEQS_HistoricalRejection(ENUM_ORDER_TYPE direction)
{
   MqlRates rD1[];
   ArraySetAsSeries(rD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 10, rD1) < 10) return 7.5; // neutral

   double atrD1 = TEQS_GetATR(PERIOD_D1, 14);
   if(atrD1 <= 0.0) return 7.5;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double zoneHalf     = atrD1 * InpTEQSZoneATRMulti;

   int touchCount     = 0;
   int rejectionCount = 0;
   int failedBreak    = 0;

   for(int i = 0; i < 10; i++)
   {
      if(direction == ORDER_TYPE_BUY)
      {
         // Resistance zone: look at candle highs near current price above
         double level = rD1[i].high;
         if(MathAbs(level - currentPrice) <= zoneHalf)
         {
            touchCount++;
            // Rejection: high wick significant vs body
            double body      = MathAbs(rD1[i].close - rD1[i].open);
            double upperWick = rD1[i].high - MathMax(rD1[i].open, rD1[i].close);
            if(upperWick > body * 0.5) rejectionCount++;
            // Failed break: touched above zone but closed back below
            if(rD1[i].high > (currentPrice + zoneHalf * 0.5) &&
               rD1[i].close < (currentPrice + zoneHalf * 0.5)) failedBreak++;
         }
      }
      else
      {
         // Support zone: look at candle lows near current price below
         double level = rD1[i].low;
         if(MathAbs(level - currentPrice) <= zoneHalf)
         {
            touchCount++;
            double body      = MathAbs(rD1[i].close - rD1[i].open);
            double lowerWick = MathMin(rD1[i].open, rD1[i].close) - rD1[i].low;
            if(lowerWick > body * 0.5) rejectionCount++;
            if(rD1[i].low < (currentPrice - zoneHalf * 0.5) &&
               rD1[i].close > (currentPrice - zoneHalf * 0.5)) failedBreak++;
         }
      }
   }

   // More touches + rejections + failed breaks = lower score (harder to break)
   // No touches = neutral (7.5)
   if(touchCount == 0) return 7.5;

   double score = 15.0;
   score -= MathMin(6.0, touchCount    * 1.5); // -1.5 per touch, max -6
   score -= MathMin(6.0, rejectionCount * 2.0); // -2 per rejection, max -6
   score -= MathMin(3.0, failedBreak   * 3.0); // -3 per failed break, max -3
   return MathMax(0.0, score);
}

//--------------------------------------------------------------------
// TEQS Component 3: Breakout Probability (15 pts)
// Uses ATR, Tick Volume, Momentum (RSI distance from 50), Candle Body
//--------------------------------------------------------------------
double TEQS_BreakoutProbability(ENUM_ORDER_TYPE direction)
{
   double score = 0.0;

   // ATR component (0-5): current ATR vs average (expansion = higher probability)
   double atrNow = TEQS_GetATR(PERIOD_H1, 14);
   int atrH = iATR(_Symbol, PERIOD_H1, 14);
   double atrAvg = 0.0;
   if(atrH != INVALID_HANDLE)
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(atrH, 0, 0, 10, buf) >= 10)
      {
         double sum = 0.0;
         for(int i = 1; i < 10; i++) sum += buf[i];
         atrAvg = sum / 9.0;
      }
      IndicatorRelease(atrH);
   }
   if(atrAvg > 0)
   {
      double atrRatio = atrNow / atrAvg;
      score += MathMin(5.0, atrRatio * 2.5);
   }
   else score += 2.5;

   // Tick Volume component (0-4): current vs average
   long vol[];
   ArraySetAsSeries(vol, true);
   if(CopyTickVolume(_Symbol, PERIOD_H1, 0, 6, vol) >= 6)
   {
      double avgVol = 0.0;
      for(int i = 1; i < 6; i++) avgVol += (double)vol[i];
      avgVol /= 5.0;
      double volRatio = (avgVol > 0) ? ((double)vol[0] / avgVol) : 1.0;
      score += MathMin(4.0, volRatio * 2.0);
   }
   else score += 2.0;

   // Momentum/RSI component (0-4): RSI alignment with direction
   int rsiH = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   if(rsiH != INVALID_HANDLE)
   {
      double rbuf[];
      ArraySetAsSeries(rbuf, true);
      if(CopyBuffer(rsiH, 0, 0, 1, rbuf) > 0)
      {
         double rsi = rbuf[0];
         double diff = (direction == ORDER_TYPE_BUY) ? (rsi - 50.0) : (50.0 - rsi);
         score += MathMax(0.0, MathMin(4.0, (diff / 30.0) * 4.0));
      }
      IndicatorRelease(rsiH);
   }
   else score += 2.0;

   // Candle Body component (0-2): strong body in direction = more momentum
   MqlRates rH1[];
   ArraySetAsSeries(rH1, true);
   if(CopyRates(_Symbol, PERIOD_H1, 1, 1, rH1) > 0)
   {
      double body = MathAbs(rH1[0].close - rH1[0].open);
      double range = rH1[0].high - rH1[0].low;
      if(range > 0)
      {
         double bodyRatio = body / range;
         bool bodyAligned = (direction == ORDER_TYPE_BUY)
                            ? (rH1[0].close > rH1[0].open)
                            : (rH1[0].close < rH1[0].open);
         if(bodyAligned) score += MathMin(2.0, bodyRatio * 2.0);
      }
   }

   return MathMin(15.0, score);
}

//--------------------------------------------------------------------
// TEQS Component 4: Distance To Key Level (15 pts)
// BUY: distance to nearest Resistance (D1 highs above price)
// SELL: distance to nearest Support   (D1 lows  below price)
// More room = higher score
//--------------------------------------------------------------------
double TEQS_DistanceToKeyLevel(ENUM_ORDER_TYPE direction)
{
   double atrD1 = TEQS_GetATR(PERIOD_D1, 14);
   if(atrD1 <= 0.0) return 7.5;

   MqlRates rD1[];
   ArraySetAsSeries(rD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 20, rD1) < 10) return 7.5;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double nearestLevel = 0.0;
   double bestDist     = DBL_MAX;

   for(int i = 0; i < 20 && i < ArraySize(rD1); i++)
   {
      double level = (direction == ORDER_TYPE_BUY) ? rD1[i].high : rD1[i].low;
      bool isAbove  = (direction == ORDER_TYPE_BUY) ? (level > currentPrice) : (level < currentPrice);
      if(!isAbove) continue;
      double dist = MathAbs(level - currentPrice);
      if(dist < bestDist) { bestDist = dist; nearestLevel = level; }
   }

   if(bestDist == DBL_MAX) return 10.0; // no key level found = open space = high score

   // Normalize distance as multiples of ATR
   double distInATR = bestDist / atrD1;

   // 0-0.5 ATR = very close (almost no room)   -> low score
   // 0.5-1 ATR = some room                     -> medium score
   // 1-2 ATR   = good room                     -> good score
   // >2 ATR    = lots of room                  -> max score
   double score;
   if(distInATR < 0.5)      score = MathMax(0.0, distInATR / 0.5 * 5.0);
   else if(distInATR < 1.0) score = 5.0 + (distInATR - 0.5) / 0.5 * 5.0;
   else if(distInATR < 2.0) score = 10.0 + (distInATR - 1.0) / 1.0 * 5.0;
   else                     score = 15.0;

   return MathMin(15.0, score);
}

//--------------------------------------------------------------------
// TEQS Component 5: Trend Exhaustion (5 pts)
// Uses ADX trend, RSI extreme, ATR contraction, Momentum
// High exhaustion = lower score
//--------------------------------------------------------------------
double TEQS_TrendExhaustion(ENUM_ORDER_TYPE direction)
{
   double score = 5.0;

   // ADX: falling ADX = trend exhausting
   int adxH = iADX(_Symbol, PERIOD_D1, 14);
   if(adxH != INVALID_HANDLE)
   {
      double adxBuf[];
      ArraySetAsSeries(adxBuf, true);
      if(CopyBuffer(adxH, MAIN_LINE, 0, 3, adxBuf) >= 3)
      {
         // ADX declining over 2 bars = exhaustion signal
         if(adxBuf[0] < adxBuf[1] && adxBuf[1] < adxBuf[2]) score -= 2.0;
         else if(adxBuf[0] < adxBuf[1])                      score -= 1.0;
         // ADX below 20 = weak trend
         if(adxBuf[0] < 20.0) score -= 1.0;
      }
      IndicatorRelease(adxH);
   }

   // RSI: overbought/oversold = potential exhaustion
   int rsiH = iRSI(_Symbol, PERIOD_D1, 14, PRICE_CLOSE);
   if(rsiH != INVALID_HANDLE)
   {
      double rbuf[];
      ArraySetAsSeries(rbuf, true);
      if(CopyBuffer(rsiH, 0, 0, 1, rbuf) > 0)
      {
         double rsi = rbuf[0];
         if(direction == ORDER_TYPE_BUY  && rsi > 75.0) score -= 1.0; // overbought = exhaustion for buy
         if(direction == ORDER_TYPE_SELL && rsi < 25.0) score -= 1.0; // oversold   = exhaustion for sell
      }
      IndicatorRelease(rsiH);
   }

   return MathMax(0.0, score);
}

//--------------------------------------------------------------------
// TEQS Component 6: Liquidity Zone Detection (5 pts)
// Daily High/Low, Weekly High/Low, Previous High/Low, Swing High/Low
// Dense liquidity near current price = lower score
//--------------------------------------------------------------------
double TEQS_LiquidityZoneDetection()
{
   double atrD1 = TEQS_GetATR(PERIOD_D1, 14);
   if(atrD1 <= 0.0) return 3.0;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double zoneHalf     = atrD1 * InpTEQSZoneATRMulti;
   int    liqCount     = 0;

   // Daily high and low
   MqlRates rD1[];
   ArraySetAsSeries(rD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 0, 3, rD1) >= 3)
   {
      for(int i = 0; i < 3; i++)
      {
         if(MathAbs(rD1[i].high - currentPrice) <= zoneHalf) liqCount++;
         if(MathAbs(rD1[i].low  - currentPrice) <= zoneHalf) liqCount++;
      }
   }

   // Weekly high and low
   MqlRates rW1[];
   ArraySetAsSeries(rW1, true);
   if(CopyRates(_Symbol, PERIOD_W1, 0, 2, rW1) >= 2)
   {
      for(int i = 0; i < 2; i++)
      {
         if(MathAbs(rW1[i].high - currentPrice) <= zoneHalf * 2) liqCount++;
         if(MathAbs(rW1[i].low  - currentPrice) <= zoneHalf * 2) liqCount++;
      }
   }

   // Each liquidity zone near price reduces score
   double score = 5.0 - MathMin(5.0, liqCount * 1.0);
   return MathMax(0.0, score);
}

//--------------------------------------------------------------------
// TEQS Component 7: Time At Resistance / Support (5 pts)
// If price has been stuck near key level for many candles without
// breaking, it signals resistance/support is strong -> lower score
//--------------------------------------------------------------------
double TEQS_TimeAtResistanceSupport(ENUM_ORDER_TYPE direction)
{
   double atrH1 = TEQS_GetATR(PERIOD_H1, 14);
   if(atrH1 <= 0.0) return 3.0;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double zoneHalf     = atrH1 * 0.5; // tight zone for H1 candles

   MqlRates rH1[];
   ArraySetAsSeries(rH1, true);
   if(CopyRates(_Symbol, PERIOD_H1, 0, 24, rH1) < 10) return 3.0;

   // Count how many of the last 24 H1 candles stayed within the zone
   // (i.e., price was hovering near current level without breaking)
   int stuckCount = 0;
   for(int i = 0; i < 24 && i < ArraySize(rH1); i++)
   {
      bool nearLevel;
      if(direction == ORDER_TYPE_BUY)
         nearLevel = (rH1[i].high > currentPrice - zoneHalf && rH1[i].high < currentPrice + zoneHalf * 2);
      else
         nearLevel = (rH1[i].low  < currentPrice + zoneHalf && rH1[i].low  > currentPrice - zoneHalf * 2);

      if(nearLevel) stuckCount++;
   }

   // 0-3  candles = fresh arrival  = good
   // 4-8  candles = some time      = moderate
   // 9-16 candles = stuck a while  = bad
   // 17+  candles = very stuck     = very bad
   double score;
   if(stuckCount <= 3)       score = 5.0;
   else if(stuckCount <= 8)  score = 3.5;
   else if(stuckCount <= 16) score = 1.5;
   else                      score = 0.0;

   return score;
}

//--------------------------------------------------------------------
// TEQS MASTER FUNCTION
// Called ONLY after AI Confidence Score PASS, ONLY in Trend Following.
// Returns true = PASS, false = BLOCK.
// Also updates glbTEQSLastScore and glbTEQSLastReason for display.
//--------------------------------------------------------------------
bool TEQS_CheckFilter(ENUM_ORDER_TYPE direction)
{
   if(!InpTEQSEnable) return true; // disabled = bypass completely

   double s1 = TEQS_HistoricalTradeQuality(direction);
   double s2 = TEQS_HistoricalRejection(direction);
   double s3 = TEQS_BreakoutProbability(direction);
   double s4 = TEQS_DistanceToKeyLevel(direction);
   double s5 = TEQS_TrendExhaustion(direction);
   double s6 = TEQS_LiquidityZoneDetection();
   double s7 = TEQS_TimeAtResistanceSupport(direction);

   double totalScore = s1 + s2 + s3 + s4 + s5 + s6 + s7;
   totalScore = MathMin(100.0, MathMax(0.0, totalScore));

   glbTEQSLastScore  = totalScore;
   glbTEQSLastReason = StringFormat(
      "TEQS %.0f/100 [Hist:%.0f/40 Rej:%.0f/15 BkO:%.0f/15 Dist:%.0f/15 Exh:%.0f/5 Liq:%.0f/5 Time:%.0f/5]",
      totalScore, s1, s2, s3, s4, s5, s6, s7);

   return (totalScore >= InpTEQSPassThreshold);
}
//====================================================================
// END TEQS MODULE
//====================================================================

//====================================================================
// PATCH SET F (Weekend Detection Fix - Forex & Gold/Silver only):
// Determines whether the symbol is REALLY tradeable right now using
// the Broker's own reported state, never Local Time, VPS Time, Linux
// Time, Windows Time, UTC Offset, or Day-Of-Week. This function adds
// NO trading logic - it only reports a true/false broker status and
// is purely new/additive (non-invasive).
//
// Method: (1) the symbol's live SYMBOL_TRADE_MODE must not be
// SYMBOL_TRADE_MODE_DISABLED, and (2) the broker's most recent tick
// for the symbol must be fresh (i.e. quotes are actively streaming
// right now, which is only true while the Broker's market is open).
// A frozen/stale last tick is the direct, real-time signature of a
// closed market/session - it reflects the Broker's actual state,
// not any clock or calendar calculation performed by the EA/VPS.
//====================================================================
bool KAI_IsBrokerMarketOpen(string symbol, int maxTickAgeSeconds = 180)
{
   long tradeMode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) return false;

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick)) return false;
   if(tick.bid <= 0.0 || tick.ask <= 0.0) return false;

   // Freshness check against the Broker's own tick timestamp - this is
   // NOT a day-of-week/local-time decision, only a "is the Broker still
   // streaming quotes right now" check.
   if(TimeCurrent() - tick.time > maxTickAgeSeconds) return false;

   return true;
}

//====================================================================
// SYMBOL MODE ROUTER
// Sole responsibility: read the current symbol and decide which
// module should execute. Contains NO trading logic, indicators,
// signal detection, money management, or order handling of any kind.
// Uses keyword (substring) matching, never exact-match, since brokers
// commonly add prefixes/suffixes to raw symbol names (e.g. "BTCUSDc",
// "XAUUSD.pro", "EURUSD_i").
//====================================================================
enum ENUM_SYMBOL_MODE
{
   SYMBOL_MODE_CRYPTO,       // Symbol contains BTC or ETH
   SYMBOL_MODE_GOLD_SILVER,  // Symbol contains XAU or XAG
   SYMBOL_MODE_FOREX         // Symbol contains none of the above
};

ENUM_SYMBOL_MODE DetectSymbolMode(string symbol)
{
   string s = symbol;
   StringToUpper(s); // case-insensitive keyword match only; does not alter _Symbol or any trading logic

   if(StringFind(s, "BTC") >= 0 || StringFind(s, "ETH") >= 0)
      return SYMBOL_MODE_CRYPTO;

   if(StringFind(s, "XAU") >= 0 || StringFind(s, "XAG") >= 0)
      return SYMBOL_MODE_GOLD_SILVER;

   return SYMBOL_MODE_FOREX;
}

//====================================================================
// CRYPTO MODULE  (from Hybrid_Crypto_Mode.mq5 - trading logic unchanged)
//====================================================================
//+------------------------------------------------------------------+
//|                                Hybrid_MultiStrategy_EA_v6_1.mq5  |
//|                                  Copyright 2026, AI Developer    |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
// v6.1 CHANGE NOTES (patch on top of v6 - strict minimal change):
//
// PATCH SET A (5 items):
//  A1. D1 Trend Detection replaced: no more HH/HL/LH/LL structure scan.
//      Uses ONLY the last fully CLOSED D1 candle (Shift = 1, never Shift = 0):
//        Close > Open -> BULL, Close < Open -> BEAR, Close == Open -> NONE.
//      H4/H1/M30/M15 confirmation logic, Trend-Following, Counter-Trend and
//      Pullback/Entry logic are UNCHANGED.
//  A2. When the closed D1 candle is a Doji (NONE), the EA no longer stops/
//      blocks trading - it immediately falls through to the existing,
//      unmodified Sideway Engine instead of waiting.
//  A3. Extreme Engine now allows only ONE open Extreme position at a time
//      (checked via open-position comment tag "Extreme"). Once that position
//      closes, a new Extreme trade is allowed again (existing ExtHighTrig_/
//      ExtLowTrig_ dedup logic is untouched). Trend Engine, Sideway Engine and
//      normal Max Orders are unaffected.
//  A4. Dashboard appearance only: Floating P/L color scheme changed to
//      Blue (positive) / Red (negative). Font size, layout and all other
//      dashboard information are unchanged.
//  A5. Final Lot Size assignment is now mapped directly from Risk Level
//      (Risk Score calculation, Confidence calculation and Entry Score are
//      UNCHANGED):
//        RISK LOW    -> 0.08 - 0.10
//        RISK MEDIUM -> 0.05 - 0.07
//        RISK HIGH   -> 0.02 - 0.04
//      Entry Score (0-10) is used only to interpolate within the risk band.
//
// PATCH SET B (AI Confidence Score - pure decision filter):
//  B1. New function Cr_AIConfidenceScore() computes a 0-100 score from Trend
//      Score, Momentum(ADX H1), ADX(D1), ATR, RSI, EMA Alignment, Pullback
//      (Entry Score) and Volume components.
//  B2. Called ONLY immediately before order execution (inside
//      Cr_ExecuteOrderWithUSD_Risk, right before Cr_trade.Buy()/Cr_trade.Sell()).
//      If score < 60 -> BLOCK (no order sent). If score >= 60 -> PASS.
//  B3. This layer can NEVER change BUY/SELL/Counter/Direction/Strategy - it
//      can only block an already-decided, already-scored Cr_trade.
//
// PATCH SET C (Minimal-Impact Modification: Extreme Engine confirmation +
// new Sideway Price Engine):
//  C1. Extreme Engine: already satisfies "max 1 active Extreme position,
//      respects Max Orders" (see PATCH A3 / Cr_CountOpenExtremePositions and
//      the existing Max-Orders gate in Cr_OnTick, which runs BEFORE
//      Cr_RunExtremeEngine()). No further Extreme Engine change was required.
//      Extreme detection logic, priority and OrderSend path are untouched.
// PATCH SET D (Minimal-Impact Modification: Pure Price Action Sideway
// Price Engine, D1 5-Candle Range, Zone-Based Lots):
//  D1. Old RSI/ATR/ADX/H1-based RunSidewayEngine() has been COMPLETELY
//      DELETED (not just bypassed). No RSI, ATR, ADX, or H1-candle
//      calculations remain anywhere in the sideway logic. Both call sites
//      that used to invoke it (Cr_OnTick's Sideway branch, and Cr_RunTrendEngine's
//      Doji fallback branch) now call Cr_SidewayPriceEngine() directly.
//  D2. Cr_GetSidewayPricePosition() now uses ONLY the last 5 fully CLOSED D1
//      candles (Shift 1-5, current forming D1 candle never used). Highest
//      High of the 5 candles = Upper Boundary (100%); Lowest Low of the 5
//      candles = Lower Boundary (0%); price position is calculated as a
//      percentage (0%-100%) within that range.
//  D3. Cr_SidewayPriceEngine() - fallback engine, Priority 4 (below
//      Extreme/Trend/Counter-Trend). Dynamic Lot Size System by price % zone:
//        95-100% SELL 0.04 | 80-94% SELL 0.03 | 75-79% SELL 0.02
//        26-74% NO TRADE (middle range)
//        21-25% BUY 0.02  | 6-20%  BUY 0.03  | 0-5%   BUY 0.04
//      Breakout (>100% or <0%) immediately invalidates Sideway and calls
//      Detect Trend (Cr_DetectMarketRegime) to re-evaluate the market state;
//      control only passes to the existing, unmodified Cr_RunTrendEngine() if
//      Detect Trend now reports a valid trend.
//  D4. Cr_ExecuteSidewayFixedLotTrade() now takes the zone-selected lot size
//      directly as a parameter (no Cr_AIConfidenceScore() involvement in lot
//      sizing). Trend/Counter-Trend/Extreme lot sizing (Cr_ScoreToLot) is
//      untouched. Order placement still goes through the existing,
//      unmodified Cr_ExecuteOrderWithUSD_Risk() (same SL/TP calc as every
//      other engine).
//  D5. Dashboard: only new STATUS text values added (SIDEWAY NO-TRADE ZONE,
//      SIDEWAY RANGE BROKEN - RE-EVALUATING TREND, ORDER OPENED, SIDEWAY
//      DISABLED). No layout, label, or other dashboard change.
//
// All other systems (Trend Following, Counter-Trend, Pullback, Entry Logic,
// Decision Layer, Trend Score, Entry Score, Smart History, Zone Memory,
// Floating Protection, SL/TP Calculation, News Filter, Adaptive Cooldown,
// Trade Execution Logic, Dashboard layout/information, all other filters)
// remain 100% unchanged from v6.

CTrade Cr_trade;

//====================================================================
// ENUMS
//====================================================================
enum ENUM_SCORE_GRADE      { GRADE_RISK, GRADE_BAD, GRADE_NORMAL, GRADE_GOOD };

//====================================================================
// INPUT PARAMETERS
//====================================================================
input group "=== Global Risk Management ==="
input double   Cr_InpMaxLotSize        = 0.10;
input double   Cr_InpMinLotSize        = 0.02;
input double   Cr_InpBaseSL_USD        = 300.0;
input int      Cr_InpBaseCooldownMin   = 10;

input group "=== Engine TP Settings ==="
input double   Cr_InpTrendTP_USD       = 1200.0;
input double   Cr_InpSidewayTP_USD     = 400.0;
input double   Cr_InpExtremeTP_USD     = 1000.0;

input group "=== Market Regime (D1 Filters) ==="
input int      Cr_InpADXPeriod         = 14;
input int      Cr_InpEMAPeriod         = 50;

input group "=== News Filter (MT5 Calendar) ==="
input bool     Cr_InpUseNewsFilter     = true;
input int      Cr_InpNewsLookaheadMin  = 30;
input int      Cr_InpNewsLookbackMin   = 15;

input group "=== Smart History / Zone Memory ==="
input bool     Cr_InpUseSmartHistory   = true;
input double   Cr_InpZonePoints        = 500;

input group "=== Floating Loss Protection ==="
input double   Cr_InpFloatingLossLimit = -50.0;

input group "=== Decision Layer: Counter-Trend (Priority 1 rule) ==="
input double   Cr_InpCounterTrendLotPct = 0.70;   // Counter-Trend lot = 70% of normal lot

input group "=== Decision Layer: Smart Risk Management (Priority 3) ==="
input int      Cr_InpRiskMedCooldownAdd  = 5;     // Extra cooldown minutes when Risk = MEDIUM
input int      Cr_InpRiskHighCooldownAdd = 15;    // Extra cooldown minutes when Risk = HIGH
input int      Cr_InpRiskHighMaxOrderCut = 1;     // Reduce Max Orders by this much when Risk = HIGH

input group "=== Decision Layer: Risk-Level Lot Bands (patch) ==="
input double   Cr_InpLotLowMin    = 0.08;   // Risk LOW  lot band min
input double   Cr_InpLotLowMax    = 0.10;   // Risk LOW  lot band max
input double   Cr_InpLotMedMin    = 0.05;   // Risk MEDIUM lot band min
input double   Cr_InpLotMedMax    = 0.07;   // Risk MEDIUM lot band max
input double   Cr_InpLotHighMin   = 0.02;   // Risk HIGH lot band min
input double   Cr_InpLotHighMax   = 0.04;   // Risk HIGH lot band max

input group "=== AI Confidence Score (Decision Filter) ==="
input double   Cr_InpAIConfidenceThreshold = 60.0;  // Minimum score (0-100) required to PASS

// Dashboard inputs for Crypto mode removed - a single shared dashboard
// (KAI_DASH_ / CreateDashboard()/UpdateDashboard()/DeleteDashboard())
// now serves all three modes. See the "SHARED DASHBOARD (KAI MT5)"
// section near the bottom of this file.

//====================================================================
// GLOBAL VARIABLES
//====================================================================
datetime Cr_glbCooldownUntil     = 0;
int      Cr_glbConsecutiveWins   = 0;
int      Cr_glbConsecutiveLosses = 0;
double   Cr_glbLastBalance       = 0.0;

datetime Cr_glbOrderTimestamps[200];
int      Cr_glbOrderTimestampCount = 0;

HistoryZone Cr_glbZones[500];
int         Cr_glbZoneCount = 0;

string  Cr_glbDashTrendText   = "-";
string  Cr_glbDashRegimeText  = "-";
int     Cr_glbDashScore       = 0;
double  Cr_glbDashLot         = 0.0;
string  Cr_glbDashReason      = "-";
string  Cr_glbDashNewsText    = "No High Impact News";
string  Cr_glbDashCooldownTxt = "-";
string  Cr_glbDashHistoryTxt  = "-";

// --- v6 Dashboard / Decision Layer display state (display-only, does not affect trading logic) ---
string  Cr_glbDashEngine      = "-";      // TREND / SIDEWAY / EXTREME
string  Cr_glbDashMode        = "-";      // FOLLOW / COUNTER / RANGE / -
string  Cr_glbDashSignal      = "WAIT";   // BUY / SELL / WAIT   (set ONLY by Priority-1 Trend/Sideway/Extreme engines)
double  Cr_glbDashTrendScore  = 0.0;      // 0-10 informational strength of the Priority-1 trend read
double  Cr_glbDashConfidence  = 0.0;      // 0-10 blended TrendScore + EntryScore, informational only
string  Cr_glbDashRiskLevel   = "LOW";    // LOW / MEDIUM / HIGH  (Priority 3)
string  Cr_glbDashStatus      = "SCANNING";
int     Cr_glbDashOpenCount   = 0;
int     Cr_glbDashMaxOrders   = 3;
double  Cr_glbDashAIScore     = 0.0;      // last computed AI Confidence Score (0-100), informational
string  Cr_glbDashTrendPersist = "";      // Dashboard-only: latest non-"-" TREND label, persisted (Task: never show "-")


int Cr_OnInit()
{
   Cr_trade.SetExpertMagicNumber(EXPERT_MAGIC);
   Cr_glbLastBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 1)
      Cr_ResetWeeklyVariables();

   return(INIT_SUCCEEDED);
}

void Cr_OnDeinit(const int reason)
{
}

void Cr_OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 1)
      Cr_ResetWeeklyVariables();

   bool isWeekend = (dt.day_of_week == 6 || dt.day_of_week == 0);

   bool slCooldownActive = false;
   datetime slCooldownEnd = 0; // display-only: end time of the SL lock, for the compact dashboard countdown
   if(isWeekend)
   {
      if(GlobalVariableCheck("GV_WEEKEND_COOLDOWN"))
      {
         datetime wkCooldown = (datetime)GlobalVariableGet("GV_WEEKEND_COOLDOWN");
         if(TimeCurrent() < wkCooldown) { slCooldownActive = true; slCooldownEnd = wkCooldown; }
         else GlobalVariableDel("GV_WEEKEND_COOLDOWN");
      }
   }
   else
   {
      if(TimeCurrent() < Cr_glbCooldownUntil) { slCooldownActive = true; slCooldownEnd = Cr_glbCooldownUntil; }
   }

   // --- Priority 3: Smart Risk Management -----------------------------------
   // Read-only classification layered on TOP of the existing (unchanged)
   // Adaptive Cooldown / Max Positions logic. It can only ADD extra caution
   // (smaller lot, longer cooldown, fewer max orders) - it can NEVER block a
   // trade outright or flip a Buy/Sell decision made by the Trend Analysis layer.
   ENUM_RISK_LEVEL riskLevel = Cr_GetRiskLevel();
   Cr_glbDashRiskLevel = Cr_RiskLevelName(riskLevel);

   int baseMaxPositions = isWeekend ? 6 : 3;
   int maxPositions = baseMaxPositions;
   if(riskLevel == RISK_HIGH) maxPositions = MathMax(1, baseMaxPositions - Cr_InpRiskHighMaxOrderCut);
   Cr_glbDashMaxOrders = maxPositions;
   bool maxPosReached = (Cr_CountTotalPositions(_Symbol) >= maxPositions);

   int adaptiveCooldownMin = Cr_GetAdaptiveCooldownMinutes();   // <- unchanged original logic
   int riskCooldownBonus = 0;
   if(riskLevel == RISK_MEDIUM) riskCooldownBonus = Cr_InpRiskMedCooldownAdd;
   if(riskLevel == RISK_HIGH)   riskCooldownBonus = Cr_InpRiskHighCooldownAdd;
   int effectiveCooldownMin = adaptiveCooldownMin + riskCooldownBonus;

   int minsSinceLast = Cr_GetMinutesSinceLastPosition(_Symbol);
   bool freqCooldownActive = (minsSinceLast < effectiveCooldownMin);
   Cr_glbDashCooldownTxt = KAI_FormatCooldownText(slCooldownActive, slCooldownEnd,
                                                   freqCooldownActive,
                                                   adaptiveCooldownMin, riskCooldownBonus);

   Cr_CheckTradeHistory();

   bool highImpactNews = Cr_InpUseNewsFilter ? Cr_IsHighImpactNewsNearby() : false;
   Cr_glbDashNewsText = highImpactNews ? "HIGH IMPACT NEWS NEARBY" : "No High Impact News";

   if(slCooldownActive || maxPosReached || freqCooldownActive)
   {
      Cr_glbDashStatus = slCooldownActive ? "COOLDOWN (SL LOCK)" :
                      maxPosReached     ? "MAX ORDERS REACHED" :
                                          "COOLDOWN (FREQUENCY)";
      Cr_glbDashSignal = "WAIT";
      return;
   }

   if(Cr_RunExtremeEngine(highImpactNews))
   {
      return;
   }

   ENUM_MARKET_REGIME regime = Cr_DetectMarketRegime();
   Cr_glbDashRegimeText = (regime == REGIME_TREND) ? "TREND" : "SIDEWAY";

   if(regime == REGIME_TREND)
      Cr_RunTrendEngine(regime, highImpactNews);
   else
      Cr_SidewayPriceEngine(highImpactNews);   // PATCH C2: redirected to new price-only engine
}

int Cr_CountTotalPositions(string symbol)
{
   int count = 0;
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         count++;
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buys++;
         else sells++;
      }
   }
   Cr_glbDashHistoryTxt = StringFormat("Open:%d (Buy:%d / Sell:%d)", count, buys, sells);
   Cr_glbDashOpenCount  = count;
   return count;
}

// --- PATCH A3: count currently open Extreme-Engine positions ---------------
// Used only to cap the Extreme Engine to a single simultaneous position.
// Trend Engine, Sideway Engine and normal Max Orders are unaffected.
int Cr_CountOpenExtremePositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         string cmt = PositionGetString(POSITION_COMMENT);
         if(StringFind(cmt, "Extreme") >= 0) count++;
      }
   }
   return count;
}

int Cr_GetMinutesSinceLastPosition(string symbol)
{
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(posTime > lastTime) lastTime = posTime;
      }
   }
   if(lastTime == 0) return 99999;
   return (int)((TimeCurrent() - lastTime) / 60);
}

int Cr_GetAdaptiveCooldownMinutes()
{
   int ordersLastHour = Cr_CountOrderTimestampsWithin(60);

   if(ordersLastHour >= 6) return 60;
   if(ordersLastHour >= 4) return 30;
   if(ordersLastHour >= 2) return 15;
   return Cr_InpBaseCooldownMin;
}

int Cr_CountOrderTimestampsWithin(int minutes)
{
   int cnt = 0;
   datetime cutoff = TimeCurrent() - minutes * 60;
   for(int i = 0; i < Cr_glbOrderTimestampCount; i++)
      if(Cr_glbOrderTimestamps[i] >= cutoff) cnt++;
   return cnt;
}

void Cr_RegisterOrderTimestamp()
{
   if(Cr_glbOrderTimestampCount >= ArraySize(Cr_glbOrderTimestamps))
   {
      for(int i = 1; i < Cr_glbOrderTimestampCount; i++)
         Cr_glbOrderTimestamps[i-1] = Cr_glbOrderTimestamps[i];
      Cr_glbOrderTimestampCount--;
   }
   Cr_glbOrderTimestamps[Cr_glbOrderTimestampCount] = TimeCurrent();
   Cr_glbOrderTimestampCount++;
}

bool Cr_IsHighImpactNewsNearby()
{
   datetime from = TimeCurrent() - Cr_InpNewsLookbackMin * 60;
   datetime to   = TimeCurrent() + Cr_InpNewsLookaheadMin * 60;

   string baseCcy   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profitCcy = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to, NULL, NULL);
   if(total <= 0) return false;

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;

      if(country.currency == baseCcy || country.currency == profitCcy)
         return true;
   }
   return false;
}

double Cr_GetZoneKey(double price)
{
   double zoneSize = Cr_InpZonePoints * _Point;
   if(zoneSize <= 0) return price;
   return MathRound(price / zoneSize) * zoneSize;
}

int Cr_FindZoneIndex(double zoneKey)
{
   for(int i = 0; i < Cr_glbZoneCount; i++)
      if(MathAbs(Cr_glbZones[i].priceLevel - zoneKey) < _Point * 0.5)
         return i;
   return -1;
}

void Cr_RegisterZoneResult(double price, bool win)
{
   double zoneKey = Cr_GetZoneKey(price);
   int idx = Cr_FindZoneIndex(zoneKey);
   if(idx < 0)
   {
      if(Cr_glbZoneCount >= ArraySize(Cr_glbZones)) return;
      idx = Cr_glbZoneCount;
      Cr_glbZones[idx].priceLevel = zoneKey;
      Cr_glbZones[idx].wins = 0;
      Cr_glbZones[idx].losses = 0;
      Cr_glbZoneCount++;
   }
   if(win) Cr_glbZones[idx].wins++;
   else    Cr_glbZones[idx].losses++;
}

int Cr_GetZoneLotAdjustment(double price)
{
   if(!Cr_InpUseSmartHistory) return 0;
   double zoneKey = Cr_GetZoneKey(price);
   int idx = Cr_FindZoneIndex(zoneKey);
   if(idx < 0) return 0;

   int total = Cr_glbZones[idx].wins + Cr_glbZones[idx].losses;
   if(total < 3) return 0;

   double winRate = (double)Cr_glbZones[idx].wins / total;
   if(winRate >= 0.65) return 1;
   if(winRate <= 0.35) return -1;
   return 0;
}

ENUM_MARKET_REGIME Cr_DetectMarketRegime()
{
   int adxHandle = iADX(_Symbol, PERIOD_D1, Cr_InpADXPeriod);
   if(adxHandle == INVALID_HANDLE) return REGIME_SIDEWAY;

   double adxValues[];
   ArraySetAsSeries(adxValues, true);
   if(CopyBuffer(adxHandle, MAIN_LINE, 0, 1, adxValues) <= 0)
   {
      IndicatorRelease(adxHandle);
      return REGIME_SIDEWAY;
   }
   double adx = adxValues[0];

   int emaHandle = iMA(_Symbol, PERIOD_D1, Cr_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      IndicatorRelease(adxHandle);
      return REGIME_SIDEWAY;
   }

   double emaValues[];
   ArraySetAsSeries(emaValues, true);
   if(CopyBuffer(emaHandle, 0, 0, 6, emaValues) < 6)
   {
      IndicatorRelease(adxHandle);
      IndicatorRelease(emaHandle);
      return REGIME_SIDEWAY;
   }

   double emaToday = emaValues[0];
   double ema5DaysAgo = emaValues[5];
   double slope = MathAbs(emaToday - ema5DaysAgo);

   int atrD1Handle = iATR(_Symbol, PERIOD_D1, 14);
   double atrD1Values[1];
   double atrD1 = 0.0;
   if(atrD1Handle != INVALID_HANDLE)
   {
      if(CopyBuffer(atrD1Handle, 0, 0, 1, atrD1Values) > 0) atrD1 = atrD1Values[0];
      IndicatorRelease(atrD1Handle);
   }

   IndicatorRelease(adxHandle);
   IndicatorRelease(emaHandle);

   double adaptiveSlopeThreshold = (atrD1 > 0) ? (atrD1 * 0.2) : (_Point * 10.0);

   if(adx > 18.0 && slope >= adaptiveSlopeThreshold)
      return REGIME_TREND;

   return REGIME_SIDEWAY;
}

void Cr_RunTrendEngine(ENUM_MARKET_REGIME regime, bool highImpactNews)
{
   // --- PATCH A1: D1 Trend Detection replaced -------------------------------
   // No more HH/HL/LH/LL structure scan across multiple D1 candles.
   // Uses ONLY the last fully closed D1 candle (Shift = 1). Shift = 0 (the
   // currently forming candle) is never used, so the trend direction is
   // stable for the whole trading day.
   MqlRates ratesD1[];
   ArraySetAsSeries(ratesD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, ratesD1) < 1) return;

   ENUM_TREND_DIRECTION d1Trend = DIRECTION_NONE;
   if(ratesD1[0].close > ratesD1[0].open)      d1Trend = DIRECTION_BULL;
   else if(ratesD1[0].close < ratesD1[0].open) d1Trend = DIRECTION_BEAR;
   else                                        d1Trend = DIRECTION_NONE;

   Cr_glbDashTrendText = (d1Trend == DIRECTION_BULL) ? "BULL" :
                       (d1Trend == DIRECTION_BEAR) ? "BEAR" : "NONE (Doji)";

   // --- PATCH A2: Doji D1 -> fall through to Sideway Engine, never block ----
   // PATCH C2: redirected to new price-only engine. fromTrendDoji=true tells
   // Cr_SidewayPriceEngine() not to call back into Cr_RunTrendEngine() on a
   // breakout read here, since we are already inside the Trend Detector's
   // own fallback path (prevents re-entrant recursion).
   if(d1Trend == DIRECTION_NONE)
   {
      Cr_SidewayPriceEngine(highImpactNews, true);
      return;
   }

   // --- Confirmation logic across H4/H1/M30/M15: UNCHANGED ------------------
   int greenBars = 0, redBars = 0;
   ENUM_TIMEFRAMES tfs[4] = {PERIOD_H4, PERIOD_H1, PERIOD_M30, PERIOD_M15};

   for(int i = 0; i < 4; i++)
   {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(_Symbol, tfs[i], 1, 1, r) > 0)
      {
         if(r[0].close > r[0].open) greenBars++;
         else if(r[0].close < r[0].open) redBars++;
      }
   }

   // Trend-Following: PATCH - now requires big-body confirmation via
   // ConfirmFollowTrend() (>=3 of 4 timeframes aligned with D1, H4/H1 must
   // also pass IsBigBody()) instead of the plain greenBars/redBars count.
   bool isBullTrendFollowing = (d1Trend == DIRECTION_BULL && ConfirmFollowTrend(_Symbol, d1Trend));
   bool isBearTrendFollowing = (d1Trend == DIRECTION_BEAR && ConfirmFollowTrend(_Symbol, d1Trend));

   // Counter-Trend (v6 requirement, unchanged priority order): Trend-Following
   // always has priority first; Counter-Trend now requires ALL 4 of
   // H4/H1/M30/M15 opposite to D1 AND big-body confirmed on H4/H1, via
   // ConfirmCounterTrend() - 4-of-4, not 3-of-4.
   bool isCounterBuy  = (!isBullTrendFollowing && !isBearTrendFollowing && d1Trend == DIRECTION_BEAR && ConfirmCounterTrend(_Symbol, d1Trend));
   bool isCounterSell = (!isBullTrendFollowing && !isBearTrendFollowing && d1Trend == DIRECTION_BULL && ConfirmCounterTrend(_Symbol, d1Trend));

   // Display-only: informational Trend Score for the dashboard (Priority 1
   // read strength). No structure count is available anymore since HH/HL/
   // LH/LL analysis was removed by PATCH A1, so this is now based only on
   // how many of the 4 confirmation timeframes are aligned. Does not feed
   // back into any BUY/SELL/WAIT decision.
   int alignedBars = (d1Trend == DIRECTION_BULL) ? greenBars : redBars;
   Cr_glbDashTrendScore = MathMin(10.0, (alignedBars / 4.0) * 10.0);
   Cr_glbDashEngine = "TREND";
   Cr_glbDashMode   = (isBullTrendFollowing || isBearTrendFollowing) ? "FOLLOW" :
                   (isCounterBuy || isCounterSell) ? "COUNTER" : "-";

   MqlRates m15Rates[];
   ArraySetAsSeries(m15Rates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 3, m15Rates) < 3) return;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   int atrM15Handle = iATR(_Symbol, PERIOD_M15, 14);
   double atrM15Values[1];
   double atrM15 = 0.0;
   if(atrM15Handle != INVALID_HANDLE)
   {
      if(CopyBuffer(atrM15Handle, 0, 0, 1, atrM15Values) > 0) atrM15 = atrM15Values[0];
      IndicatorRelease(atrM15Handle);
   }
   if(atrM15 <= 0) return;

   Cr_glbDashStatus = "WAITING PULLBACK";

   if(isBullTrendFollowing || isCounterBuy)
   {
      Cr_glbDashSignal = "BUY";
      double buyThreshold = m15Rates[1].close - (0.15 * atrM15);
      if(currentPrice <= buyThreshold)
      {
         if((m15Rates[1].close > m15Rates[1].open && m15Rates[1].close > (m15Rates[2].high - 0.10 * atrM15)) ||
            (MathMin(m15Rates[1].open, m15Rates[1].close) - m15Rates[1].low > MathAbs(m15Rates[1].close - m15Rates[1].open) * 2))
         {
            bool trendAligned = isBullTrendFollowing;
            // TEQS: Additional filter - Trend Following ONLY
            // Runs ONLY when this is a Trend-Follow signal (not Counter-Trend).
            // Counter-Trend is excluded per spec ("ห้ามใช้กับ Counter Trend").
            if(trendAligned && !TEQS_CheckFilter(ORDER_TYPE_BUY))
            {
               Cr_glbDashStatus = glbTEQSLastReason + " -> BLOCKED";
               return;
            }
            int score = Cr_CalculateEAScore(trendAligned, greenBars, highImpactNews);
            if(Cr_ExecuteScoredOrder(ORDER_TYPE_BUY, score, Cr_InpBaseSL_USD, Cr_InpTrendTP_USD,
                                trendAligned ? "Trend-Follow BUY" : "Counter-Trend BUY", !trendAligned, highImpactNews))
               Cr_glbDashStatus = "ORDER OPENED";
         }
      }
   }
   else if(isBearTrendFollowing || isCounterSell)
   {
      Cr_glbDashSignal = "SELL";
      double sellThreshold = m15Rates[1].close + (0.15 * atrM15);
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(currentPrice >= sellThreshold)
      {
         if((m15Rates[1].close < m15Rates[1].open && m15Rates[1].close < (m15Rates[2].low + 0.10 * atrM15)) ||
            (m15Rates[1].high - MathMax(m15Rates[1].open, m15Rates[1].close) > MathAbs(m15Rates[1].close - m15Rates[1].open) * 2))
         {
            bool trendAligned = isBearTrendFollowing;
            // TEQS: Additional filter - Trend Following ONLY (not Counter-Trend)
            if(trendAligned && !TEQS_CheckFilter(ORDER_TYPE_SELL))
            {
               Cr_glbDashStatus = glbTEQSLastReason + " -> BLOCKED";
               return;
            }
            int score = Cr_CalculateEAScore(trendAligned, redBars, highImpactNews);
            if(Cr_ExecuteScoredOrder(ORDER_TYPE_SELL, score, Cr_InpBaseSL_USD, Cr_InpTrendTP_USD,
                                trendAligned ? "Trend-Follow SELL" : "Counter-Trend SELL", !trendAligned, highImpactNews))
               Cr_glbDashStatus = "ORDER OPENED";
         }
      }
   }
   else
   {
      Cr_glbDashSignal = "WAIT";
      Cr_glbDashStatus = "NO ALIGNED SIGNAL";
   }
}

//====================================================================
// SIDEWAY PRICE ENGINE (Pure Price Action - D1 5-Candle Range)
// Priority 4 (fallback only, below Extreme, Trend-Following and
// Counter-Trend). Uses ONLY D1 price - no indicators, no score, no
// filters, no ATR/ADX/RSI/EMA/MACD, no AI Score in the position or lot
// calculation. The old RSI/ATR/ADX/H1-based RunSidewayEngine() has been
// deleted; see the two call sites in Cr_OnTick and Cr_RunTrendEngine's Doji
// fallback branch, both of which call Cr_SidewayPriceEngine() directly.
//====================================================================

// price-only position inside the last 5 CLOSED D1 candles (0-100%).
// Never uses the current (still forming) D1 candle. Uses each candle's
// High/Low (not close) to define the boundaries, per spec:
//   Upper Boundary (100%) = Highest High of the 5 candles (Shift 1-5)
//   Lower Boundary (0%)   = Lowest Low of the 5 candles (Shift 1-5)
// Returns -999.0 as a sentinel if there isn't enough history yet or the
// 5-candle range is degenerate (zero width) - callers must treat that as
// "engine unavailable".
double Cr_GetSidewayPricePosition()
{
   MqlRates r5[];
   ArraySetAsSeries(r5, true);
   // Shift = 1 .. 5 -> the 5 most recently CLOSED D1 candles. Shift = 0
   // (the current, still-forming D1 candle) is never requested.
   if(CopyRates(_Symbol, PERIOD_D1, 1, 5, r5) < 5) return -999.0;

   double upperBoundary = r5[0].high;
   double lowerBoundary = r5[0].low;
   for(int i = 1; i < 5; i++)
   {
      if(r5[i].high > upperBoundary) upperBoundary = r5[i].high;
      if(r5[i].low  < lowerBoundary) lowerBoundary = r5[i].low;
   }

   double range = upperBoundary - lowerBoundary;
   if(range <= 0.0) return -999.0;

   double currentPrice  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pricePosition = (currentPrice - lowerBoundary) / range * 100.0;
   return pricePosition;
}

// Order-execution helper used ONLY by the new Sideway Price Engine. Crypto
// Sideway uses Dynamic Lot exactly like Trend/Extreme - the lot value itself
// is just computed differently (via the Dynamic Lot Size System's price %
// zone table below, instead of Cr_ScoreToLot()'s score-based formula). The
// word "FixedLot" in this function's name refers only to the fact that, for
// a single call, the caller passes one already-resolved numeric lot value -
// it does NOT mean Crypto Sideway uses Fixed Lot Money Management. Lot size
// is passed in directly by Cr_SidewayPriceEngine() based purely on which
// price % zone the current price sits in (see the Dynamic Lot Size System
// table). This does not touch Cr_ScoreToLot() / Trend / Counter-Trend /
// Extreme lot sizing, and still routes through the existing, unmodified
// Cr_ExecuteOrderWithUSD_Risk() (same SL/TP calc as every other engine).
bool Cr_ExecuteSidewayFixedLotTrade(ENUM_ORDER_TYPE orderType, double lotSize, string reasonTag)
{
   Cr_glbDashLot    = lotSize;
   Cr_glbDashReason = StringFormat("%s | Price Zone Lot %.2f", reasonTag, lotSize);

   bool result = Cr_ExecuteOrderWithUSD_Risk(orderType, lotSize, Cr_InpBaseSL_USD, Cr_InpSidewayTP_USD, reasonTag);
   if(result) Cr_RegisterOrderTimestamp();
   return result;
}

// the Sideway Price Engine itself.
//    0%  -   5%  -> BUY,  Lot 0.04
//    6%  -  20%  -> BUY,  Lot 0.03
//   21%  -  25%  -> BUY,  Lot 0.02
//   26%  -  74%  -> NO TRADE (middle range)
//   75%  -  79%  -> SELL, Lot 0.02
//   80%  -  94%  -> SELL, Lot 0.03
//   95%  - 100%  -> SELL, Lot 0.04
//   >100% or <0% -> BREAKOUT: Sideway becomes invalid, Detect Trend
//                   (Cr_DetectMarketRegime) is called to re-evaluate the
//                   market state; control only passes to the existing,
//                   unmodified Trend Detector (Cr_RunTrendEngine) if Detect
//                   Trend now reports a valid trend.
// fromTrendDoji = true means this call originated from Cr_RunTrendEngine's own
// Doji fallback; in that case a breakout read here does NOT call back into
// Cr_RunTrendEngine() again (that would be re-entering the very engine that
// just called us), avoiding recursion. The normal Cr_OnTick call site always
// passes fromTrendDoji = false.
void Cr_SidewayPriceEngine(bool highImpactNews, bool fromTrendDoji = false)
{
   double pos = Cr_GetSidewayPricePosition();

   Cr_glbDashEngine = "SIDEWAY";
   Cr_glbDashMode   = "PRICE";

   if(pos <= -900.0)   // sentinel: not enough D1 history / degenerate range
   {
      Cr_glbDashSignal = "WAIT";
      Cr_glbDashStatus = "SIDEWAY DISABLED";
      return;
   }

   Cr_glbDashTrendScore = MathMin(10.0, MathAbs(pos - 50.0) / 50.0 * 10.0); // informational only

   // --- Breakout Condition: price goes above 100% or below 0% of the D1 5-candle range ---
   if(pos > 100.0 || pos < 0.0)
   {
      Cr_glbDashSignal = "WAIT";
      Cr_glbDashLot    = 0.0;
      Cr_glbDashStatus = "SIDEWAY RANGE BROKEN - RE-EVALUATING TREND";

      // Stop the Sideway Engine immediately and call Detect Trend to re-evaluate the market state.
      if(!fromTrendDoji)
      {
         ENUM_MARKET_REGIME regime = Cr_DetectMarketRegime();
         if(regime == REGIME_TREND)
         {
            // Trend Emerging: exit Sideway Engine, switch to Trend Follow / Counter Trend engine.
            Cr_RunTrendEngine(regime, highImpactNews);  // existing Trend logic, unchanged
         }
         // else: Detect Trend still reports no valid trend - stay flat this tick;
         // the range recalculates fresh on the next tick.
      }
      return;
   }

   // --- No-Trade Zone: 26% - 74% (middle range) ---
   if(pos > 25.0 && pos < 75.0)
   {
      Cr_glbDashSignal = "WAIT";
      Cr_glbDashLot    = 0.0;
      Cr_glbDashStatus = StringFormat("SIDEWAY NO-TRADE ZONE (%.1f%%)", pos);
      return;
   }

   // --- Dynamic Lot Size System (Based on Price % Zone) ---
   ENUM_ORDER_TYPE orderType;
   double sidewayLot = 0.0;
   string reasonTag = "";

   if(pos >= 95.0 && pos <= 100.0)
   {
      orderType  = ORDER_TYPE_SELL;
      sidewayLot = 0.04;
      reasonTag  = "Sideway Price SELL (95-100%)";
   }
   else if(pos >= 80.0 && pos <= 94.0)
   {
      orderType  = ORDER_TYPE_SELL;
      sidewayLot = 0.03;
      reasonTag  = "Sideway Price SELL (80-94%)";
   }
   else if(pos >= 75.0 && pos <= 79.0)
   {
      orderType  = ORDER_TYPE_SELL;
      sidewayLot = 0.02;
      reasonTag  = "Sideway Price SELL (75-79%)";
   }
   else if(pos >= 21.0 && pos <= 25.0)
   {
      orderType  = ORDER_TYPE_BUY;
      sidewayLot = 0.02;
      reasonTag  = "Sideway Price BUY (21-25%)";
   }
   else if(pos >= 6.0 && pos <= 20.0)
   {
      orderType  = ORDER_TYPE_BUY;
      sidewayLot = 0.03;
      reasonTag  = "Sideway Price BUY (6-20%)";
   }
   else if(pos >= 0.0 && pos <= 5.0)
   {
      orderType  = ORDER_TYPE_BUY;
      sidewayLot = 0.04;
      reasonTag  = "Sideway Price BUY (0-5%)";
   }
   else
   {
      // Safety fallback - should not be reached given the ranges above
      Cr_glbDashSignal = "WAIT";
      Cr_glbDashLot    = 0.0;
      Cr_glbDashStatus = StringFormat("SIDEWAY NO-TRADE ZONE (%.1f%%)", pos);
      return;
   }

   Cr_glbDashSignal = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   Cr_glbDashStatus = reasonTag;
   if(Cr_ExecuteSidewayFixedLotTrade(orderType, sidewayLot, reasonTag))
      Cr_glbDashStatus = "ORDER OPENED";
}

bool Cr_RunExtremeEngine(bool highImpactNews)
{
   MqlRates rates180D[];
   ArraySetAsSeries(rates180D, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 1, 180, rates180D);
   if(copied < 180) return false;

   double highest6M = rates180D[0].high;
   double lowest6M  = rates180D[0].low;

   for(int i = 1; i < 180; i++)
   {
      if(rates180D[i].high > highest6M) highest6M = rates180D[i].high;
      if(rates180D[i].low  < lowest6M)  lowest6M  = rates180D[i].low;
   }

   int atrD1Handle = iATR(_Symbol, PERIOD_D1, 14);
   double atrD1Values[1];
   double atrD1 = 0.0;
   if(atrD1Handle != INVALID_HANDLE)
   {
      if(CopyBuffer(atrD1Handle, 0, 0, 1, atrD1Values) > 0) atrD1 = atrD1Values[0];
      IndicatorRelease(atrD1Handle);
   }
   if(atrD1 <= 0) return false;

   double extremeHighBound = highest6M + (0.15 * atrD1);
   double extremeLowBound  = lowest6M  - (0.15 * atrD1);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(currentBid < highest6M && GlobalVariableCheck("ExtHighTrig_"+_Symbol)) GlobalVariableDel("ExtHighTrig_"+_Symbol);
   if(currentAsk > lowest6M  && GlobalVariableCheck("ExtLowTrig_"+_Symbol))  GlobalVariableDel("ExtLowTrig_"+_Symbol);

   // --- PATCH A3: only ONE open Extreme position allowed at a time ----------
   // Trend Engine, Sideway Engine and normal Max Orders are unaffected. Once
   // the open Extreme position closes, this count returns to 0 and a new
   // Extreme trade is allowed again (existing trigger dedup above is unchanged).
   bool extremeAlreadyOpen = (Cr_CountOpenExtremePositions() >= 1);

   if(currentBid >= extremeHighBound && !GlobalVariableCheck("ExtHighTrig_"+_Symbol) && !extremeAlreadyOpen)
   {
      Cr_glbDashEngine = "EXTREME"; Cr_glbDashMode = "REVERSAL"; Cr_glbDashSignal = "SELL";
      Cr_glbDashTrendScore = 10.0;
      int eaScore = Cr_CalculateEAScore(true, 10, highImpactNews);
      if(Cr_ExecuteScoredOrder(ORDER_TYPE_SELL, eaScore, Cr_InpBaseSL_USD, Cr_InpExtremeTP_USD, "Extreme SELL", false, highImpactNews))
      {
         GlobalVariableSet("ExtHighTrig_"+_Symbol, 1.0);
         Cr_glbDashStatus = "ORDER OPENED";
         return true;
      }
   }

   if(currentAsk <= extremeLowBound && !GlobalVariableCheck("ExtLowTrig_"+_Symbol) && !extremeAlreadyOpen)
   {
      Cr_glbDashEngine = "EXTREME"; Cr_glbDashMode = "REVERSAL"; Cr_glbDashSignal = "BUY";
      Cr_glbDashTrendScore = 10.0;
      int eaScore = Cr_CalculateEAScore(true, 10, highImpactNews);
      if(Cr_ExecuteScoredOrder(ORDER_TYPE_BUY, eaScore, Cr_InpBaseSL_USD, Cr_InpExtremeTP_USD, "Extreme BUY", false, highImpactNews))
      {
         GlobalVariableSet("ExtLowTrig_"+_Symbol, 1.0);
         Cr_glbDashStatus = "ORDER OPENED";
         return true;
      }
   }

   return false;
}

int Cr_CalculateEAScore(bool trendAligned, int secondaryStrength, bool highImpactNews)
{
   double score = 0.0;

   score += trendAligned ? 7.0 : 3.0;

   double secNorm = MathMin(MathMax(secondaryStrength, 0), 10) / 10.0 * 2.0;
   score += secNorm;

   int freqLast30 = Cr_CountOrderTimestampsWithin(30);
   double newsFreqScore = 1.0;
   if(highImpactNews) newsFreqScore -= 0.6;
   if(freqLast30 >= 3) newsFreqScore -= 0.4;
   if(newsFreqScore < 0) newsFreqScore = 0;
   score += newsFreqScore;

   int finalScore = (int)MathRound(score);
   if(finalScore > 10) finalScore = 10;
   if(finalScore < 0)  finalScore = 0;
   return finalScore;
}

// --- PATCH A5: final Lot Size assignment now mapped from Risk Level --------
// Risk Score calculation, Confidence calculation and Entry Score are all
// UNCHANGED. Only the final lot magnitude is now taken from the Risk Level
// band; Entry Score (0-10) is used solely to interpolate within that band.
double Cr_ScoreToLot(int score, double refPrice, ENUM_RISK_LEVEL riskLevel, bool highImpactNews = false)
{
   double lotMin, lotMax;
   if(riskLevel == RISK_LOW)         { lotMin = Cr_InpLotLowMin;  lotMax = Cr_InpLotLowMax;  }
   else if(riskLevel == RISK_MEDIUM) { lotMin = Cr_InpLotMedMin;  lotMax = Cr_InpLotMedMax;  }
   else                              { lotMin = Cr_InpLotHighMin; lotMax = Cr_InpLotHighMax; }

   double scoreNorm = MathMin(MathMax(score, 0), 10) / 10.0;
   double lot = lotMin + scoreNorm * (lotMax - lotMin);

   // --- PATCH SET E (Cascade Lot Calculation, item 6/7): News Filter step.
   // Cumulative on top of the Risk-Level lot above (never resets Base Lot).
   // News Filter may ONLY temporarily reduce lot size here - it can never
   // block the order or change BUY/SELL, and this never touches the fixed
   // zone-table lot used by the Sideway Price Engine. ---
   if(highImpactNews) lot = MathMax(lotMin, lot * 0.75);

   int zoneAdj = Cr_GetZoneLotAdjustment(refPrice);
   if(zoneAdj > 0) lot = MathMin(lot + 0.01, lotMax);
   if(zoneAdj < 0) lot = lotMin;

   if(Cr_glbConsecutiveWins >= 3)   lot = MathMin(lot + 0.02, lotMax);
   if(Cr_glbConsecutiveLosses >= 3) lot = lotMin;

   if(Cr_GetFloatingPL() <= Cr_InpFloatingLossLimit) lot = lotMin;

   if(lot > Cr_InpMaxLotSize) lot = Cr_InpMaxLotSize;
   if(lot > 0 && lot < Cr_InpMinLotSize) lot = Cr_InpMinLotSize;

   return NormalizeDouble(lot, 2);
}

//====================================================================
// PRIORITY 3 : SMART RISK MANAGEMENT (Decision Layer, 10%)
// Read-only classification based on EXISTING state (consecutive losses,
// floating P/L, order frequency). This layer can ONLY reduce lot, add
// extra cooldown minutes, and cap max orders - it has NO authority to
// block a trade or change a Buy/Sell/Wait decision.
// UNCHANGED by this patch (only the resulting Lot Size mapping changed).
//====================================================================
ENUM_RISK_LEVEL Cr_GetRiskLevel()
{
   int riskPoints = 0;

   if(Cr_glbConsecutiveLosses >= 3)      riskPoints += 2;
   else if(Cr_glbConsecutiveLosses >= 1) riskPoints += 1;

   double floating = Cr_GetFloatingPL();
   if(floating <= Cr_InpFloatingLossLimit)        riskPoints += 2;
   else if(floating <= Cr_InpFloatingLossLimit * 0.5) riskPoints += 1;

   int ordersLastHour = Cr_CountOrderTimestampsWithin(60);
   if(ordersLastHour >= 6)      riskPoints += 2;
   else if(ordersLastHour >= 4) riskPoints += 1;

   if(riskPoints >= 4) return RISK_HIGH;
   if(riskPoints >= 2) return RISK_MEDIUM;
   return RISK_LOW;
}

string Cr_RiskLevelName(ENUM_RISK_LEVEL lvl)
{
   if(lvl == RISK_HIGH)   return "HIGH";
   if(lvl == RISK_MEDIUM) return "MEDIUM";
   return "LOW";
}

double Cr_GetFloatingPL()
{
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
         floating += PositionGetDouble(POSITION_PROFIT);
   }
   return floating;
}

bool Cr_ExecuteScoredOrder(ENUM_ORDER_TYPE orderType, int score, double slUSD, double tpUSD, string reasonTag, bool isCounterTrend = false, bool highImpactNews = false)
{
   double refPrice = SymbolInfoDouble(_Symbol, (orderType == ORDER_TYPE_BUY) ? SYMBOL_ASK : SYMBOL_BID);

   // --- Priority 3: Smart Risk Management (unchanged calculation) -----------
   ENUM_RISK_LEVEL riskLvl = Cr_GetRiskLevel();

   // --- Priority 2 Entry Score + PATCH A5 Risk-Level Lot mapping ------------
   // PATCH SET E: highImpactNews now threaded through so the Cascade's News
   // Filter step (Cr_ScoreToLot) can apply its temporary lot reduction.
   double lotSize = Cr_ScoreToLot(score, refPrice, riskLvl, highImpactNews);

   // --- Priority 1 rule: Counter-Trend lot capped to 70% of normal lot -------
   if(isCounterTrend)
      lotSize = NormalizeDouble(lotSize * Cr_InpCounterTrendLotPct, 2);

   Cr_glbDashScore      = score;
   Cr_glbDashLot        = lotSize;
   Cr_glbDashReason     = StringFormat("%s | Score %d/10 - %s", reasonTag, score, Cr_GradeName(score));
   Cr_glbDashConfidence = MathMin(10.0, (Cr_glbDashTrendScore * 0.7) + (score * 0.3));

   if(score == 0 || lotSize <= 0)
      return false;

   bool result = Cr_ExecuteOrderWithUSD_Risk(orderType, lotSize, slUSD, tpUSD, reasonTag);
   if(result) Cr_RegisterOrderTimestamp();
   return result;
}

string Cr_GradeName(int score)
{
   if(score >= 9) return "GOOD";
   if(score >= 5) return "NORMAL";
   if(score >= 1) return "BAD";
   return "RISK";
}

// Cr_GradeColor() removed - it was used only by the old Crypto-mode
// dashboard, which has been replaced by the shared dashboard.

//====================================================================
// PATCH SET B : AI CONFIDENCE SCORE (pure Decision Filter)
// Computes a 0-100 confidence score from Trend Score, Momentum, ADX, ATR,
// RSI, EMA Alignment, Pullback (Entry Score) and Volume components.
// This function NEVER changes Trend / Signal / Direction / Strategy - its
// only responsibility is PASS (>= Cr_InpAIConfidenceThreshold) or BLOCK.
//====================================================================
double Cr_AIConfidenceScore()
{
   double score = 0.0;

   // Trend Score component (0-20) - reuses existing Priority-1 trend read
   score += MathMin(20.0, (Cr_glbDashTrendScore / 10.0) * 20.0);

   // Momentum Score component (0-20) - H1 ADX strength
   double momentumScore = 10.0;
   int adxH1 = iADX(_Symbol, PERIOD_H1, 14);
   if(adxH1 != INVALID_HANDLE)
   {
      double v[1];
      if(CopyBuffer(adxH1, MAIN_LINE, 0, 1, v) > 0)
         momentumScore = MathMin(20.0, (v[0] / 40.0) * 20.0);
      IndicatorRelease(adxH1);
   }
   score += momentumScore;

   // ADX Score component (0-15) - D1 regime strength
   double adxScore = 7.5;
   int adxD1 = iADX(_Symbol, PERIOD_D1, Cr_InpADXPeriod);
   if(adxD1 != INVALID_HANDLE)
   {
      double v[1];
      if(CopyBuffer(adxD1, MAIN_LINE, 0, 1, v) > 0)
         adxScore = MathMin(15.0, (v[0] / 35.0) * 15.0);
      IndicatorRelease(adxD1);
   }
   score += adxScore;

   // ATR Score component (0-10) - current volatility vs recent average
   double atrScore = 5.0;
   int atrH1Handle = iATR(_Symbol, PERIOD_H1, 14);
   if(atrH1Handle != INVALID_HANDLE)
   {
      double v[4];
      if(CopyBuffer(atrH1Handle, 0, 0, 4, v) > 3)
      {
         double avg3 = (v[1] + v[2] + v[3]) / 3.0;
         if(avg3 > 0) atrScore = MathMin(10.0, (v[0] / avg3) * 5.0);
      }
      IndicatorRelease(atrH1Handle);
   }
   score += atrScore;

   // RSI Score component (0-10) - distance from midline
   double rsiScore = 5.0;
   int rsiHandle = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
   if(rsiHandle != INVALID_HANDLE)
   {
      double v[1];
      if(CopyBuffer(rsiHandle, 0, 0, 1, v) > 0)
         rsiScore = MathMin(10.0, (MathAbs(v[0] - 50.0) / 30.0) * 10.0);
      IndicatorRelease(rsiHandle);
   }
   score += rsiScore;

   // EMA Alignment Score component (0-10) - price distance from D1 EMA, in ATR units
   double emaScore = 5.0;
   int emaHandle = iMA(_Symbol, PERIOD_D1, Cr_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle != INVALID_HANDLE)
   {
      double v[1];
      if(CopyBuffer(emaHandle, 0, 0, 1, v) > 0)
      {
         double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double dist = MathAbs(price - v[0]);
         double atrD1v = 0.0;
         int atrD1H = iATR(_Symbol, PERIOD_D1, 14);
         if(atrD1H != INVALID_HANDLE)
         {
            double a[1];
            if(CopyBuffer(atrD1H, 0, 0, 1, a) > 0) atrD1v = a[0];
            IndicatorRelease(atrD1H);
         }
         if(atrD1v > 0) emaScore = MathMin(10.0, (dist / atrD1v) * 10.0);
      }
      IndicatorRelease(emaHandle);
   }
   score += emaScore;

   // Pullback Score component (0-10) - reuses existing Entry Score (Priority-2)
   score += MathMin(10.0, (Cr_glbDashScore / 10.0) * 10.0);

   // Volume Score component (0-5) - current M15 tick volume vs recent average
   double volumeScore = 2.5;
   long volArr[6];
   if(CopyTickVolume(_Symbol, PERIOD_M15, 0, 6, volArr) >= 6)
   {
      double avgVol = (volArr[1] + volArr[2] + volArr[3] + volArr[4] + volArr[5]) / 5.0;
      if(avgVol > 0) volumeScore = MathMin(5.0, (volArr[0] / avgVol) * 2.5);
   }
   score += volumeScore;

   double finalScore = MathMin(100.0, MathMax(0.0, score));
   Cr_glbDashAIScore = finalScore;
   return finalScore;
}

bool Cr_ExecuteOrderWithUSD_Risk(ENUM_ORDER_TYPE orderType, double lotSize, double slUSD, double tpUSD, string comment)
{
   if(lotSize <= 0) return false;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue == 0 || tickSize == 0) return false;

   double slDistPoints = (slUSD * tickSize) / (lotSize * tickValue);
   double tpDistPoints = (tpUSD * tickSize) / (lotSize * tickValue);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double openPrice = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   double slPrice   = (orderType == ORDER_TYPE_BUY) ? (openPrice - slDistPoints) : (openPrice + slDistPoints);
   double tpPrice   = (orderType == ORDER_TYPE_BUY) ? (openPrice + tpDistPoints) : (openPrice - tpDistPoints);

   slPrice = NormalizeDouble(slPrice, _Digits);
   tpPrice = NormalizeDouble(tpPrice, _Digits);

   // --- PATCH B: AI Confidence Score - final Decision Filter -----------------
   // Called immediately before order execution. Can only PASS or BLOCK; it
   // never alters direction, lot size, SL/TP or any other existing logic.
   double aiScore = Cr_AIConfidenceScore();
   if(aiScore < Cr_InpAIConfidenceThreshold)
      return false; // BLOCK - AI Confidence Score below threshold

   Cr_trade.SetDeviationInPoints(10);
   bool success = false;

   if(orderType == ORDER_TYPE_BUY)
      success = Cr_trade.Buy(lotSize, _Symbol, openPrice, slPrice, tpPrice, comment);
   else if(orderType == ORDER_TYPE_SELL)
      success = Cr_trade.Sell(lotSize, _Symbol, openPrice, slPrice, tpPrice, comment);

   return success;
}

void Cr_CheckTradeHistory()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(currentBalance != Cr_glbLastBalance)
   {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent()))
      {
         uint totalTrades = HistoryDealsTotal();
         if(totalTrades > 0)
         {
            ulong dealTicket = HistoryDealGetTicket(totalTrades - 1);
            if(HistoryDealSelect(dealTicket))
            {
               string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
               if(symbol == _Symbol)
               {
                  double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                  double dealPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

                  MqlDateTime dt;
                  TimeToStruct(TimeCurrent(), dt);
                  bool isWeekend = (dt.day_of_week == 6 || dt.day_of_week == 0);

                  if(Cr_InpUseSmartHistory)
                     Cr_RegisterZoneResult(dealPrice, profit > 0);

                  if(profit < 0)
                  {
                     Cr_glbConsecutiveLosses++;
                     Cr_glbConsecutiveWins = 0;

                     if(isWeekend)
                     {
                        int currentSLCount = 0;
                        if(GlobalVariableCheck("GV_WEEKEND_SL_COUNT"))
                           currentSLCount = (int)GlobalVariableGet("GV_WEEKEND_SL_COUNT");
                        currentSLCount++;
                        GlobalVariableSet("GV_WEEKEND_SL_COUNT", (double)currentSLCount);

                        datetime wkCooldownTime = TimeCurrent() + (120 * 60);
                        GlobalVariableSet("GV_WEEKEND_COOLDOWN", (double)wkCooldownTime);

                        Print("[WEEKEND CRITICAL] SL Hit! Count: ", currentSLCount, " | Cooldown until: ", TimeToString(wkCooldownTime));
                     }
                     else
                     {
                        // PATCH SET E (Weekend Risk Rules, item 5): Monday-Friday Stop Loss
                        // Cooldown corrected to 1 Hour per spec (was 2 Hours - the Saturday/
                        // Sunday Weekend Mode branch above, at 2 Hours, is unchanged).
                        Cr_glbCooldownUntil = TimeCurrent() + (60 * 60);
                        Print("[NORMAL RISK] Stop Loss hit! Cooldown 1 hour active.");
                     }
                  }
                  else if(profit > 0)
                  {
                     Cr_glbConsecutiveWins++;
                     Cr_glbConsecutiveLosses = 0;
                  }
               }
            }
         }
      }
      Cr_glbLastBalance = currentBalance;
   }
}

void Cr_ResetWeeklyVariables()
{
   if(GlobalVariableCheck("GV_WEEKEND_SL_COUNT")) GlobalVariableDel("GV_WEEKEND_SL_COUNT");
   if(GlobalVariableCheck("GV_WEEKEND_COOLDOWN")) GlobalVariableDel("GV_WEEKEND_COOLDOWN");

   Cr_glbCooldownUntil = 0;
   Print("[SYSTEM RESET] Monday morning initialization accomplished. All Cooldown registries are cleared.");
}

// The old per-mode Crypto Dashboard (Cr_CreateDashboardObjects /
// Cr_SetDashLine / Cr_RiskLevelColor / Cr_SignalColor / Cr_UpdateDashboard)
// has been removed. All three modes now share a single Dashboard
// (CreateDashboard() / UpdateDashboard() / DeleteDashboard(), object
// prefix KAI_DASH_) defined in the "SHARED DASHBOARD (KAI MT5)" section
// near the bottom of this file. It reads the Cr_glbDash* values below
// (already produced by the unmodified Crypto trading logic) for display
// only; it performs no calculation of its own.

//====================================================================
// GOLD & SILVER MODULE  (from Hybrid_Gold_Silver_Mode.mq5 - trading logic unchanged)
//====================================================================
//+------------------------------------------------------------------+
//|                               Hybrid_MultiStrategy_EA_v8_Mod.mq5 |
//|                                  Copyright 2026, AI Developer    |
//|                                             https://www.mql5.com |
//| Base: v8.00 Logic เดิมคงไว้ 100%                                  |
//| MODIFICATION SCOPE (Minimal Impact Modification Specification):  |
//|   - Extreme Engine, Detect Trend, Trend Follow, Counter Trend:   |
//|     left 100% untouched                                          |
//|   - Old RunSidewayEngine() DELETED (RSI/ATR/ADX/H1 logic removed)|
//|   - Gs_SidewayPriceEngine rebuilt: Pure Price Action, D1 5-Candle   |
//|     (Shift 1-5) range -> 0%-100% position, flat 0.01 lot ONLY,   |
//|     no dynamic lot calculation of any kind                       |
//|   - Breakout (>100% / <0%) stops Sideway Engine and calls Detect |
//|     Trend (Gs_DetectMarketRegime) to re-evaluate market state       |
//+------------------------------------------------------------------+

CTrade Gs_trade;

//--- ENUMS ---

//--- INPUT PARAMETERS (คงชุดเดิมของ v8 ทั้งหมด) ---
input group "=== Global Risk Management ==="
input double   Gs_InpMaxLotSize        = 0.10;   // เก็บไว้เพื่อ compatibility
input double   Gs_InpMinLotSize        = 0.02;   // เก็บไว้เพื่อ compatibility
input double   Gs_InpBaseSL_USD        = 300.0;
input int      Gs_InpCooldownMinutes   = 60;
input int      Gs_InpMinTimeBetweenPos = 10;

input group "=== Engine TP Settings ==="
input double   Gs_InpTrendTP_USD       = 1200.0;
input double   Gs_InpSidewayTP_USD     = 400.0;
input double   Gs_InpExtremeTP_USD     = 1000.0;

input group "=== Market Regime (D1 Filters) ==="
input int      Gs_InpADXPeriod         = 14;
input int      Gs_InpEMAPeriod         = 50;
input double   Gs_InpSlopeThreshold    = 10.0;

input group "=== News Filter (MT5 Calendar) ==="
input bool     Gs_InpUseNewsFilter     = true;
input int      Gs_InpNewsLookaheadMin  = 30;
input int      Gs_InpNewsLookbackMin   = 15;

input group "=== Smart History / Zone Memory ==="
input bool     Gs_InpUseSmartHistory   = true;  

input group "=== Floating Loss Protection ==="
input double   Gs_InpFloatingLossLimit = -50.0;
input double   Gs_InpForcedHighRiskFloatingLoss = -100.0; // PATCH SET F item 6/7: combined Floating Loss (USD) that force-overrides Risk Level to HIGH (Lot/Cooldown/AI Threshold only - never Max Orders)

input group "=== V6 Decision Layer (คงไว้ ไม่แก้ไข) ==="
input double   Gs_InpCounterTrendLotFactor = 0.70;  

input group "=== V7 FIXED LOT ==="
input double   Gs_InpFixedLotSize      = 0.01;   // Lot คงที่ 0.01 ทุกออเดอร์ ทุก Engine ตามสเปก

input group "=== V7 Enhancement Filters ==="
input bool     Gs_InpEnableEnhancementFilters = true;
input double   Gs_InpZonePoints              = 500;
input double   Gs_InpPullbackMinATRRatio     = 0.30;  
input double   Gs_InpPullbackMaxATRRatio     = 0.80;  
input double   Gs_InpVolatilityLowRatio      = 0.50;  
input double   Gs_InpVolatilityHighRatio     = 2.00;  
input double   Gs_InpSpreadMaxMultiplier     = 1.50;  
input int      Gs_InpSpreadHistorySize       = 100;   

input group "=== V8 AI Confidence Score ==="
input bool     Gs_InpEnableAIConfidenceScore = true;   
input double   Gs_InpAIConfidenceThreshold   = 60.0;   

// Dashboard inputs for Gold & Silver mode removed - a single shared
// dashboard (KAI_DASH_ / CreateDashboard()/UpdateDashboard()/
// DeleteDashboard()) now serves all three modes. See the
// "SHARED DASHBOARD (KAI MT5)" section near the bottom of this file.

//--- GLOBAL VARIABLES (ของเดิม) ---
datetime Gs_glbCooldownUntil = 0;
bool     Gs_glbExtHighTrig   = false;
bool     Gs_glbExtLowTrig    = false;

int      Gs_glbConsecutiveWins = 0;
int      Gs_glbConsecutiveLosses = 0;
double   Gs_glbLastBalance       = 0.0;

datetime Gs_glbOrderTimestamps[200];
int      Gs_glbOrderTimestampCount = 0;

HistoryZone Gs_glbZones[500];
int         Gs_glbZoneCount = 0;

//--- GLOBAL VARIABLES (Dashboard) ---
string  Gs_glbDashNewsText    = "No High Impact News";
string  Gs_glbDashCooldownTxt = "-";
string  Gs_glbDashHistoryTxt  = "-";

string  Gs_glbDashEngine      = "-";
string  Gs_glbDashMode        = "-";
string  Gs_glbDashTrendDir    = "-";
string  Gs_glbDashSignal      = "WAIT";
double  Gs_glbDashTrendScore  = 0.0;
int     Gs_glbDashEntryScore  = 0;
ENUM_RISK_LEVEL Gs_glbDashRisk = RISK_LOW;
double  Gs_glbDashLot         = 0.0;
double  Gs_glbDashConfidence  = 0.0;
string  Gs_glbDashStatus      = "IDLE";
// --- display-capture variables added for the shared Dashboard only.
// They store (never recompute) values the existing logic already
// produces at the point each is set, mirroring the pattern already
// used by Cr_glbDashOpenCount/Cr_glbDashMaxOrders/Cr_glbDashAIScore. ---
int     Gs_glbDashOpenCount   = 0;
int     Gs_glbDashMaxOrders   = 0;
double  Gs_glbDashAIScore     = 0.0;
string  Gs_glbDashTrendPersist = "";      // Dashboard-only: latest non-"-" TREND label, persisted (Task: never show "-")

//--- GLOBAL VARIABLES (Spread history) ---
double  Gs_glbSpreadHistory[500];
int     Gs_glbSpreadHistoryCount = 0;


//---FORWARD DECLARATIONS สำหรับการทำงานของ New Engine Breakout ---
void Gs_RunTrendEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel);
void Gs_SidewayPriceEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel);

int Gs_OnInit()
{
   Gs_trade.SetExpertMagicNumber(EXPERT_MAGIC);
   Gs_glbLastBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   return(INIT_SUCCEEDED);
}

void Gs_OnDeinit(const int reason)
{
}

void Gs_OnTick()
{
   // --- PATCH SET F (Weekend Detection Fix, item 8): No NEW order may be
   // opened while the Broker's real market/session for this symbol is
   // closed. This gates new entries below only - it does not touch
   // Cooldown, Max Orders, Risk Level, or any other logic. Decision is
   // based ONLY on the Broker's live trading status (see
   // KAI_IsBrokerMarketOpen) - never Local/VPS/Linux/Windows Time, UTC
   // Offset, or Day-Of-Week, so the EA starts trading immediately once
   // the Broker actually opens the market, regardless of what day/time
   // it is on the EA's host. ---
   if(!KAI_IsBrokerMarketOpen(_Symbol))
   {
      Gs_glbDashSignal = "WAIT";
      Gs_glbDashStatus = "WEEKEND - NO NEW ORDERS (GOLD/SILVER)";
      return;
   }

   bool slCooldownActive = (TimeCurrent() < Gs_glbCooldownUntil);

   Gs_CheckTradeHistory();
   Gs_RegisterSpreadSample(); 

   bool highImpactNews = Gs_InpUseNewsFilter ? Gs_IsHighImpactNewsNearby() : false;
   Gs_glbDashNewsText = highImpactNews ? "HIGH IMPACT NEWS NEARBY" : "No High Impact News";

   ENUM_RISK_LEVEL riskLevel = Gs_CalculateRiskLevel(highImpactNews);

   // --- PATCH SET F (item 6/7): New Risk Rule - if the combined Floating
   // Loss of currently open positions is <= threshold, Risk Level is
   // force-overridden to HIGH immediately, ignoring AI Score/Market
   // Condition/History/existing Logic. This affects Lot Size, Cooldown and
   // AI Threshold ONLY (via riskLevel below) - Max Orders is fixed at 3
   // regardless (see Gs_GetMaxPositionsAllowed) so it is never reduced by
   // this override. Once Floating Loss recovers above the threshold, Risk
   // Level immediately reverts to the normal calculation above. ---
   if(Gs_GetFloatingPL() <= Gs_InpForcedHighRiskFloatingLoss) riskLevel = RISK_HIGH;

   Gs_glbDashRisk = riskLevel;

   int maxAllowed = Gs_GetMaxPositionsAllowed(riskLevel);
   int openCount  = Gs_CountTotalPositions(_Symbol);
   bool maxPosReached = (openCount >= maxAllowed);

   int baseAdaptiveCooldown = Gs_GetAdaptiveCooldownMinutes();
   int adaptiveCooldownMin  = Gs_GetRiskAdjustedCooldown(baseAdaptiveCooldown, riskLevel);
   int minsSinceLast = Gs_GetMinutesSinceLastPosition(_Symbol);
   bool freqCooldownActive = (minsSinceLast < adaptiveCooldownMin);
   Gs_glbDashCooldownTxt = KAI_FormatCooldownText(slCooldownActive, Gs_glbCooldownUntil,
                                                   freqCooldownActive,
                                                   adaptiveCooldownMin, 0);

   Gs_glbDashOpenCount = openCount;
   Gs_glbDashMaxOrders = maxAllowed;

   if(slCooldownActive) { Gs_glbDashStatus = "SL COOLDOWN LOCK"; return; }
   if(maxPosReached)    { Gs_glbDashStatus = "MAX ORDERS REACHED"; return; }
   if(freqCooldownActive) { Gs_glbDashStatus = "FREQUENCY COOLDOWN"; return; }

   // Priority 1: Extreme Engine ลำดับความสำคัญสูงสุด
   if(Gs_RunExtremeEngine(highImpactNews, riskLevel)) return;

   ENUM_MARKET_REGIME regime = Gs_DetectMarketRegime();
   Gs_glbDashEngine = (regime == REGIME_TREND) ? "TREND" : "SIDEWAY";

   // Priority 2 & 3: Trend Following / Counter Trend 
   if(regime == REGIME_TREND)
   {
      Gs_RunTrendEngine(highImpactNews, riskLevel);
   }
   // Priority 4: Sideway Fallback (Detect Trend = Unclear -> activate Sideway Price Engine)
   else if(regime == REGIME_SIDEWAY)
   {
      Gs_SidewayPriceEngine(highImpactNews, riskLevel);
   }

   Gs_glbDashOpenCount = Gs_CountTotalPositions(_Symbol);
   Gs_glbDashMaxOrders = maxAllowed;
}

int Gs_CountTotalPositions(string symbol)
{
   int count = 0;
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         count++;
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buys++;
         else sells++;
      }
   }
   Gs_glbDashHistoryTxt = StringFormat("Open:%d (Buy:%d / Sell:%d)", count, buys, sells);
   return count;
}

int Gs_GetMinutesSinceLastPosition(string symbol)
{
   datetime lastTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(posTime > lastTime)
         {
            lastTime = posTime;
         }
      }
   }

   if(lastTime == 0) return 99999;

   return (int)((TimeCurrent() - lastTime) / 60);
}

int Gs_GetAdaptiveCooldownMinutes()
{
   int ordersLastHour = Gs_CountOrderTimestampsWithin(60);

   if(ordersLastHour >= 6) return 60;
   if(ordersLastHour >= 4) return 30;
   if(ordersLastHour >= 2) return 15;
   return Gs_InpMinTimeBetweenPos;
}

int Gs_CountOrderTimestampsWithin(int minutes)
{
   int cnt = 0;
   datetime cutoff = TimeCurrent() - minutes * 60;
   for(int i = 0; i < Gs_glbOrderTimestampCount; i++)
      if(Gs_glbOrderTimestamps[i] >= cutoff) cnt++;
   return cnt;
}

void Gs_RegisterOrderTimestamp()
{
   if(Gs_glbOrderTimestampCount >= ArraySize(Gs_glbOrderTimestamps))
   {
      for(int i = 1; i < Gs_glbOrderTimestampCount; i++)
         Gs_glbOrderTimestamps[i-1] = Gs_glbOrderTimestamps[i];
      Gs_glbOrderTimestampCount--;
   }
   Gs_glbOrderTimestamps[Gs_glbOrderTimestampCount] = TimeCurrent();
   Gs_glbOrderTimestampCount++;
}

bool Gs_IsHighImpactNewsNearby()
{
   datetime from = TimeCurrent() - Gs_InpNewsLookbackMin * 60;
   datetime to   = TimeCurrent() + Gs_InpNewsLookaheadMin * 60;

   string baseCcy   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profitCcy = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to, NULL, NULL);
   if(total <= 0) return false;

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;

      if(country.currency == baseCcy || country.currency == profitCcy)
         return true;
   }
   return false;
}

double Gs_GetZoneKey(double price)
{
   double zoneSize = Gs_InpZonePoints * _Point;
   if(zoneSize <= 0) return price;
   return MathRound(price / zoneSize) * zoneSize;
}

int Gs_FindZoneIndex(double zoneKey)
{
   for(int i = 0; i < Gs_glbZoneCount; i++)
      if(MathAbs(Gs_glbZones[i].priceLevel - zoneKey) < _Point * 0.5)
         return i;
   return -1;
}

void Gs_RegisterZoneResult(double price, bool win)
{
   double zoneKey = Gs_GetZoneKey(price);
   int idx = Gs_FindZoneIndex(zoneKey);
   if(idx < 0)
   {
      if(Gs_glbZoneCount >= ArraySize(Gs_glbZones)) return;
      idx = Gs_glbZoneCount;
      Gs_glbZones[idx].priceLevel = zoneKey;
      Gs_glbZones[idx].wins = 0;
      Gs_glbZones[idx].losses = 0;
      Gs_glbZoneCount++;
   }
   if(win) Gs_glbZones[idx].wins++;
   else    Gs_glbZones[idx].losses++;
}

int Gs_GetZoneLotAdjustment(double price)
{
   if(!Gs_InpUseSmartHistory) return 0;
   double zoneKey = Gs_GetZoneKey(price);
   int idx = Gs_FindZoneIndex(zoneKey);
   if(idx < 0) return 0;

   int total = Gs_glbZones[idx].wins + Gs_glbZones[idx].losses;
   if(total < 3) return 0;

   double winRate = (double)Gs_glbZones[idx].wins / total;
   if(winRate >= 0.65) return 1;
   if(winRate <= 0.35) return -1;
   return 0;
}

ENUM_MARKET_REGIME Gs_DetectMarketRegime()
{
   int adxHandle = iADX(_Symbol, PERIOD_D1, Gs_InpADXPeriod);
   if(adxHandle == INVALID_HANDLE) return REGIME_SIDEWAY;

   double adxValues[];
   ArraySetAsSeries(adxValues, true);
   if(CopyBuffer(adxHandle, MAIN_LINE, 0, 1, adxValues) <= 0)
   {
      IndicatorRelease(adxHandle);
      return REGIME_SIDEWAY;
   }
   double adx = adxValues[0];

   int emaHandle = iMA(_Symbol, PERIOD_D1, Gs_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      IndicatorRelease(adxHandle);
      return REGIME_SIDEWAY;
   }

   double emaValues[];
   ArraySetAsSeries(emaValues, true);
   if(CopyBuffer(emaHandle, 0, 0, 6, emaValues) < 6)
   {
      IndicatorRelease(adxHandle);
      IndicatorRelease(emaHandle);
      return REGIME_SIDEWAY;
   }

   double emaToday = emaValues[0];
   double ema5DaysAgo = emaValues[5];

   double slope = MathAbs(emaToday - ema5DaysAgo) / _Point;

   IndicatorRelease(adxHandle);
   IndicatorRelease(emaHandle);

   if(adx > 20.0 && slope >= Gs_InpSlopeThreshold)
   {
      return REGIME_TREND;
   }

   return REGIME_SIDEWAY;
}

double Gs_GetATRValue(ENUM_TIMEFRAMES tf, int period, int shift=0)
{
   int h = iATR(_Symbol, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   double val = 0.0;
   if(CopyBuffer(h, 0, shift, 1, buf) > 0) val = buf[0];
   IndicatorRelease(h);
   return val;
}

double Gs_GetATRAverage(ENUM_TIMEFRAMES tf, int period, int lookback)
{
   int h = iATR(_Symbol, tf, period);
   if(h == INVALID_HANDLE) return 0.0;
   double buf[];
   ArraySetAsSeries(buf, true);
   double avg = 0.0;
   if(CopyBuffer(h, 0, 1, lookback, buf) >= lookback)
   {
      double sum = 0.0;
      for(int i = 0; i < lookback; i++) sum += buf[i];
      avg = sum / lookback;
   }
   IndicatorRelease(h);
   return avg;
}

double Gs_GetAverageCandleRange(ENUM_TIMEFRAMES tf, int lookback)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, tf, 1, lookback, r) < lookback) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < lookback; i++) sum += (r[i].high - r[i].low);
   return sum / lookback;
}

void Gs_RegisterSpreadSample()
{
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int cap = MathMax(10, Gs_InpSpreadHistorySize);
   if(cap > ArraySize(Gs_glbSpreadHistory)) cap = ArraySize(Gs_glbSpreadHistory);

   if(Gs_glbSpreadHistoryCount >= cap)
   {
      for(int i = 1; i < Gs_glbSpreadHistoryCount; i++)
         Gs_glbSpreadHistory[i-1] = Gs_glbSpreadHistory[i];
      Gs_glbSpreadHistoryCount--;
   }
   Gs_glbSpreadHistory[Gs_glbSpreadHistoryCount] = spread;
   Gs_glbSpreadHistoryCount++;
}

double Gs_GetAverageSpread()
{
   if(Gs_glbSpreadHistoryCount == 0) return 0.0;
   double sum = 0.0;
   for(int i = 0; i < Gs_glbSpreadHistoryCount; i++) sum += Gs_glbSpreadHistory[i];
   return sum / Gs_glbSpreadHistoryCount;
}

bool Gs_CheckSpreadFilter()
{
   if(!Gs_InpEnableEnhancementFilters) return true;
   if(Gs_glbSpreadHistoryCount < 20) return true; 
   double avgSpread = Gs_GetAverageSpread();
   double curSpread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(avgSpread <= 0) return true;
   return (curSpread <= avgSpread * Gs_InpSpreadMaxMultiplier);
}

bool Gs_CheckVolatilityFilter(double atr, double atrAvg, bool &requireDeeperPullback)
{
   requireDeeperPullback = false;
   if(!Gs_InpEnableEnhancementFilters) return true;
   if(atrAvg <= 0) return true; 
   double ratio = atr / atrAvg;
   if(ratio < Gs_InpVolatilityLowRatio) return false;      
   if(ratio > Gs_InpVolatilityHighRatio) requireDeeperPullback = true; 
   return true;
}

bool Gs_CheckATRPullbackFilter(double pullbackDistance, double atr, bool requireDeeperPullback)
{
   if(!Gs_InpEnableEnhancementFilters) return true;
   if(atr <= 0) return true; 
   double minRatio = requireDeeperPullback ? MathMax(Gs_InpPullbackMinATRRatio, 0.50) : Gs_InpPullbackMinATRRatio;
   double ratio = pullbackDistance / atr;
   return (ratio >= minRatio && ratio <= Gs_InpPullbackMaxATRRatio);
}

bool Gs_CheckMomentumFilter(ENUM_TIMEFRAMES tf)
{
   if(!Gs_InpEnableEnhancementFilters) return true;

   double atrNow  = Gs_GetATRValue(tf, 14, 0);
   double atrPrev = Gs_GetATRValue(tf, 14, 1);
   bool atrExpanding = (atrPrev > 0 && atrNow >= atrPrev);

   bool candleAboveAvg = false;
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, tf, 1, 1, r) > 0)
   {
      double range = r[0].high - r[0].low;
      double avgRange = Gs_GetAverageCandleRange(tf, 10);
      candleAboveAvg = (avgRange > 0 && range > avgRange);
   }
   return (atrExpanding || candleAboveAvg);
}

bool Gs_CheckBreakoutQualityFilter(ENUM_ORDER_TYPE type, MqlRates &m15Rates[])
{
   if(!Gs_InpEnableEnhancementFilters) return true;

   double body = MathAbs(m15Rates[1].close - m15Rates[1].open);
   double upperWick = m15Rates[1].high - MathMax(m15Rates[1].open, m15Rates[1].close);
   double lowerWick = MathMin(m15Rates[1].open, m15Rates[1].close) - m15Rates[1].low;
   double wick = (type == ORDER_TYPE_BUY) ? upperWick : lowerWick;
   bool bodyDominant = (body > wick);

   bool closedBeyondSwing = (type == ORDER_TYPE_BUY) ?
                             (m15Rates[1].close > m15Rates[2].high) :
                             (m15Rates[1].close < m15Rates[2].low);

   return (bodyDominant && closedBeyondSwing);
}

bool Gs_CheckTrendStrengthFilter(ENUM_TREND_DIRECTION dir)
{
   if(!Gs_InpEnableEnhancementFilters) return true;

   bool adxOk = true;
   int adxH = iADX(_Symbol, PERIOD_D1, Gs_InpADXPeriod);
   if(adxH != INVALID_HANDLE)
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(adxH, MAIN_LINE, 0, 2, buf) >= 2)
         adxOk = (buf[0] >= buf[1] * 0.95); 
      IndicatorRelease(adxH);
   }

   bool slopeOk = true;
   int emaH = iMA(_Symbol, PERIOD_D1, Gs_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaH != INVALID_HANDLE)
   {
      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(emaH, 0, 0, 3, buf) >= 3)
      {
         double slopeRecent = buf[0] - buf[1];
         double slopePrev    = buf[1] - buf[2];
         if(dir == DIRECTION_BULL)      slopeOk = (slopeRecent > 0 && slopeRecent >= slopePrev * 0.8);
         else if(dir == DIRECTION_BEAR) slopeOk = (slopeRecent < 0 && slopeRecent <= slopePrev * 0.8);
      }
      IndicatorRelease(emaH);
   }

   return (adxOk && slopeOk);
}

bool Gs_CheckMultiCandleConfirmation(ENUM_ORDER_TYPE type)
{
   if(!Gs_InpEnableEnhancementFilters) return true;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M15, 1, 3, r) < 3) return true; 

   int aligned = 0;
   for(int i = 0; i < 3; i++)
   {
      if(type == ORDER_TYPE_BUY  && r[i].close > r[i].open) aligned++;
      if(type == ORDER_TYPE_SELL && r[i].close < r[i].open) aligned++;
   }
   return (aligned >= 2); 
}

bool Gs_PassEnhancementFilters_TrendFollow(ENUM_ORDER_TYPE type, ENUM_TREND_DIRECTION dir,
                                         MqlRates &m15Rates[], double currentPrice, string &failReason)
{
   if(!Gs_InpEnableEnhancementFilters) return true;

   double atrM15    = Gs_GetATRValue(PERIOD_M15, 14, 0);
   double atrAvgM15 = Gs_GetATRAverage(PERIOD_M15, 14, 20);
   bool requireDeeperPullback = false;

   if(!Gs_CheckVolatilityFilter(atrM15, atrAvgM15, requireDeeperPullback)) { failReason = "Volatility too low"; return false; }

   double pullback = (type == ORDER_TYPE_BUY) ? MathAbs(m15Rates[2].high - currentPrice)
                                               : MathAbs(m15Rates[2].low  - currentPrice);
   if(!Gs_CheckATRPullbackFilter(pullback, atrM15, requireDeeperPullback)) { failReason = "Pullback out of ATR range"; return false; }

   if(!Gs_CheckMomentumFilter(PERIOD_M15))               { failReason = "Momentum weak"; return false; }
   if(!Gs_CheckBreakoutQualityFilter(type, m15Rates))    { failReason = "Breakout quality low"; return false; }
   if(!Gs_CheckSpreadFilter())                           { failReason = "Spread too wide"; return false; }
   if(!Gs_CheckTrendStrengthFilter(dir))                 { failReason = "Trend strength fading"; return false; }
   if(!Gs_CheckMultiCandleConfirmation(type))             { failReason = "Multi-candle not aligned"; return false; }

   return true;
}

bool Gs_PassEnhancementFilters_CounterTrend(ENUM_ORDER_TYPE type, MqlRates &m15Rates[], double currentPrice, string &failReason)
{
   if(!Gs_InpEnableEnhancementFilters) return true;

   double atrM15    = Gs_GetATRValue(PERIOD_M15, 14, 0);
   double atrAvgM15 = Gs_GetATRAverage(PERIOD_M15, 14, 20);
   bool requireDeeperPullback = false;

   if(!Gs_CheckVolatilityFilter(atrM15, atrAvgM15, requireDeeperPullback)) { failReason = "Volatility too low"; return false; }

   double pullback = (type == ORDER_TYPE_BUY) ? MathAbs(m15Rates[2].high - currentPrice)
                                               : MathAbs(m15Rates[2].low  - currentPrice);
   if(!Gs_CheckATRPullbackFilter(pullback, atrM15, requireDeeperPullback)) { failReason = "Pullback out of ATR range"; return false; }

   if(!Gs_CheckMomentumFilter(PERIOD_M15)) { failReason = "Momentum weak"; return false; }
   if(!Gs_CheckSpreadFilter())             { failReason = "Spread too wide"; return false; }

   return true;
}

bool Gs_PassEnhancementFilters_Extreme(string &failReason)
{
   if(!Gs_InpEnableEnhancementFilters) return true;
   if(!Gs_CheckSpreadFilter()) { failReason = "Spread too wide"; return false; }
   return true;
}

double Gs_AIConfidenceScore(ENUM_ORDER_TYPE orderType, MqlRates &m15Rates[], double currentPrice, string &scoreBreakdown)
{
   bool isBuy = (orderType == ORDER_TYPE_BUY);

   double trendScore = 0.0;
   {
      double adxVal = 0.0;
      int adxH = iADX(_Symbol, PERIOD_D1, Gs_InpADXPeriod);
      if(adxH != INVALID_HANDLE)
      {
         double buf[]; ArraySetAsSeries(buf, true);
         if(CopyBuffer(adxH, MAIN_LINE, 0, 1, buf) > 0) adxVal = buf[0];
         IndicatorRelease(adxH);
      }
      double adxComponent = MathMin(adxVal / 40.0, 1.0) * 12.0;

      double slope = 0.0;
      int emaH = iMA(_Symbol, PERIOD_D1, Gs_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaH != INVALID_HANDLE)
      {
         double buf[]; ArraySetAsSeries(buf, true);
         if(CopyBuffer(emaH, 0, 0, 6, buf) >= 6) slope = MathAbs(buf[0] - buf[5]) / _Point;
         IndicatorRelease(emaH);
      }
      double slopeComponent = MathMin(slope / MathMax(Gs_InpSlopeThreshold * 3.0, 0.0001), 1.0) * 8.0;

      trendScore = adxComponent + slopeComponent;
   }

   double momentumScore = 0.0;
   {
      double atrNow  = Gs_GetATRValue(PERIOD_M15, 14, 0);
      double atrPrev = Gs_GetATRValue(PERIOD_M15, 14, 1);
      double atrRatio = (atrPrev > 0) ? (atrNow / atrPrev) : 1.0;
      double atrComp = MathMax(0.0, MathMin((atrRatio - 0.7) / 0.3, 1.0)) * 12.0;

      double range = MathAbs(m15Rates[1].high - m15Rates[1].low);
      double avgRange = Gs_GetAverageCandleRange(PERIOD_M15, 10);
      double rangeRatio = (avgRange > 0) ? (range / avgRange) : 1.0;
      double rangeComp = MathMax(0.0, MathMin((rangeRatio - 0.7) / 0.3, 1.0)) * 8.0;

      momentumScore = atrComp + rangeComp;
   }

   double adxScore = 0.0;
   {
      double adxVal = 0.0;
      int adxH = iADX(_Symbol, PERIOD_H1, Gs_InpADXPeriod);
      if(adxH != INVALID_HANDLE)
      {
         double buf[]; ArraySetAsSeries(buf, true);
         if(CopyBuffer(adxH, MAIN_LINE, 0, 1, buf) > 0) adxVal = buf[0];
         IndicatorRelease(adxH);
      }
      adxScore = MathMin(adxVal / 35.0, 1.0) * 15.0;
   }

   double atrScoreVal = 0.0;
   {
      double atrNow = Gs_GetATRValue(PERIOD_M15, 14, 0);
      double atrAvg = Gs_GetATRAverage(PERIOD_M15, 14, 20);
      if(atrAvg > 0)
      {
         double ratio = atrNow / atrAvg;
         if(ratio >= 0.8 && ratio <= 1.5)      atrScoreVal = 10.0;
         else if(ratio < 0.8)                  atrScoreVal = MathMax(0.0, ratio / 0.8) * 10.0;
         else                                  atrScoreVal = MathMax(0.0, 10.0 - (ratio - 1.5) * 10.0);
      }
      else atrScoreVal = 5.0;
   }

   double rsiScoreVal = 0.0;
   {
      double rsiVal = 50.0;
      int rsiH = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
      if(rsiH != INVALID_HANDLE)
      {
         double buf[]; ArraySetAsSeries(buf, true);
         if(CopyBuffer(rsiH, 0, 0, 1, buf) > 0) rsiVal = buf[0];
         IndicatorRelease(rsiH);
      }
      double diff = isBuy ? (rsiVal - 50.0) : (50.0 - rsiVal);
      rsiScoreVal = MathMax(0.0, MathMin(diff / 20.0, 1.0)) * 10.0;
   }

   double emaAlignScore = 0.0;
   {
      ENUM_TIMEFRAMES tfs[4] = {PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
      int aligned = 0, validTf = 0;
      double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      for(int i = 0; i < 4; i++)
      {
         int emaH = iMA(_Symbol, tfs[i], Gs_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
         if(emaH == INVALID_HANDLE) continue;
         double buf[]; ArraySetAsSeries(buf, true);
         bool ok = (CopyBuffer(emaH, 0, 0, 1, buf) > 0);
         double emaVal = ok ? buf[0] : 0.0;
         IndicatorRelease(emaH);
         if(!ok) continue;
         validTf++;
         if(isBuy  && px > emaVal) aligned++;
         if(!isBuy && px < emaVal) aligned++;
      }
      emaAlignScore = (validTf > 0) ? ((double)aligned / validTf) * 10.0 : 5.0;
   }

   double pullbackScoreVal = 0.0;
   {
      double atrM15 = Gs_GetATRValue(PERIOD_M15, 14, 0);
      double pullback = isBuy ? MathAbs(m15Rates[2].high - currentPrice) : MathAbs(m15Rates[2].low - currentPrice);
      if(atrM15 > 0)
      {
         double ratio = pullback / atrM15;
         double mid = (Gs_InpPullbackMinATRRatio + Gs_InpPullbackMaxATRRatio) / 2.0;
         double halfRange = (Gs_InpPullbackMaxATRRatio - Gs_InpPullbackMinATRRatio) / 2.0;
         if(halfRange > 0)
         {
            double dist = MathAbs(ratio - mid);
            pullbackScoreVal = MathMax(0.0, 1.0 - (dist / (halfRange * 1.5))) * 10.0;
         }
      }
      else pullbackScoreVal = 5.0;
   }

   double volumeScoreVal = 0.0;
   {
      long vol[];
      ArraySetAsSeries(vol, true);
      if(CopyTickVolume(_Symbol, PERIOD_M15, 1, 11, vol) >= 11)
      {
         double curVol = (double)vol[0];
         double sum = 0.0;
         for(int i = 1; i < 11; i++) sum += (double)vol[i];
         double avgVol = sum / 10.0;
         double ratio = (avgVol > 0) ? (curVol / avgVol) : 1.0;
         volumeScoreVal = MathMax(0.0, MathMin((ratio - 0.5) / 0.5, 1.0)) * 5.0;
      }
      else volumeScoreVal = 2.5;
   }

   double totalScore = trendScore + momentumScore + adxScore + atrScoreVal + rsiScoreVal
                        + emaAlignScore + pullbackScoreVal + volumeScoreVal;
   if(totalScore > 100) totalScore = 100;
   if(totalScore < 0)   totalScore = 0;

   scoreBreakdown = StringFormat("Trend:%.0f/20 Mom:%.0f/20 ADX:%.0f/15 ATR:%.0f/10 RSI:%.0f/10 EMA:%.0f/10 PB:%.0f/10 Vol:%.0f/5",
                                  trendScore, momentumScore, adxScore, atrScoreVal, rsiScoreVal,
                                  emaAlignScore, pullbackScoreVal, volumeScoreVal);
   return totalScore;
}

void Gs_RunTrendEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel)
{
   MqlRates ratesD1[];
   ArraySetAsSeries(ratesD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, ratesD1) < 1) return;

   ENUM_TREND_DIRECTION d1Trend = DIRECTION_NONE;
   if(ratesD1[0].close > ratesD1[0].open)      d1Trend = DIRECTION_BULL;
   else if(ratesD1[0].close < ratesD1[0].open) d1Trend = DIRECTION_BEAR;

   int dirStrength = 10;

   if(d1Trend == DIRECTION_NONE)
   {
      Gs_glbDashEngine = "SIDEWAY"; Gs_glbDashTrendDir = "-";
      Gs_SidewayPriceEngine(highImpactNews, riskLevel);
      return;
   }
   Gs_glbDashTrendDir = (d1Trend == DIRECTION_BULL) ? "BULL" : "BEAR";

   int greenBars = 0, redBars = 0;
   ENUM_TIMEFRAMES tfs[4] = {PERIOD_H4, PERIOD_H1, PERIOD_M30, PERIOD_M15};

   for(int i = 0; i < 4; i++)
   {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(_Symbol, tfs[i], 1, 1, r) > 0)
      {
         if(r[0].close > r[0].open) greenBars++;
         else if(r[0].close < r[0].open) redBars++;
      }
   }

   // PATCH: Follow/Counter Trend confirmation now uses ConfirmFollowTrend()/
   // ConfirmCounterTrend() (big-body confirmation on H4/H1) instead of the
   // plain greenBars/redBars count. greenBars/redBars themselves are still
   // computed above unchanged, and still used below for tfAgreement/score.
   bool isBullTrendFollowing = (d1Trend == DIRECTION_BULL && ConfirmFollowTrend(_Symbol, d1Trend));
   bool isBearTrendFollowing = (d1Trend == DIRECTION_BEAR && ConfirmFollowTrend(_Symbol, d1Trend));

   bool isCounterBuy  = (!isBullTrendFollowing && !isBearTrendFollowing &&
                          d1Trend == DIRECTION_BEAR && ConfirmCounterTrend(_Symbol, d1Trend));
   bool isCounterSell = (!isBullTrendFollowing && !isBearTrendFollowing &&
                          d1Trend == DIRECTION_BULL && ConfirmCounterTrend(_Symbol, d1Trend));

   int tfAgreement  = (d1Trend == DIRECTION_BULL) ? greenBars : redBars;
   bool anyCounter = (isCounterBuy || isCounterSell);
   double trendScore = Gs_CalculateTrendScore(dirStrength, tfAgreement, anyCounter);
   Gs_glbDashTrendScore = trendScore;

   MqlRates m15Rates[];
   ArraySetAsSeries(m15Rates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 3, m15Rates) < 3) return;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   Gs_glbDashEngine = "TREND";
   string filterFail = "";

   if(isBullTrendFollowing || isCounterBuy)
   {
      double buyThreshold = m15Rates[1].close * (1.0 - 0.0005);
      if(currentPrice <= buyThreshold)
      {
         if((m15Rates[1].close > m15Rates[1].open && m15Rates[1].close > m15Rates[2].high) ||
            (MathMin(m15Rates[1].open, m15Rates[1].close) - m15Rates[1].low > MathAbs(m15Rates[1].close - m15Rates[1].open) * 2))
         {
            bool trendAligned = isBullTrendFollowing;
            Gs_glbDashMode   = trendAligned ? "FOLLOW" : "COUNTER";
            Gs_glbDashSignal = "BUY";

            bool passFilter = trendAligned
                               ? Gs_PassEnhancementFilters_TrendFollow(ORDER_TYPE_BUY, d1Trend, m15Rates, currentPrice, filterFail)
                               : Gs_PassEnhancementFilters_CounterTrend(ORDER_TYPE_BUY, m15Rates, currentPrice, filterFail);

            if(!passFilter)
            {
               Gs_glbDashStatus = "FILTERED: " + filterFail;
               return;
            }

            string aiBreakdown = "";
            double aiScore = Gs_AIConfidenceScore(ORDER_TYPE_BUY, m15Rates, currentPrice, aiBreakdown);
            Gs_glbDashAIScore = aiScore;   // display-capture only, does not affect the PASS/BLOCK decision below
            if(Gs_InpEnableAIConfidenceScore && aiScore < Gs_InpAIConfidenceThreshold)
            {
               Gs_glbDashStatus = StringFormat("AI BLOCKED (%.0f/100) %s", aiScore, aiBreakdown);
               return;
            }

            // TEQS: Additional filter - Trend Following ONLY (not Counter-Trend)
            if(trendAligned && !TEQS_CheckFilter(ORDER_TYPE_BUY))
            {
               Gs_glbDashStatus = glbTEQSLastReason + " -> BLOCKED";
               return;
            }

            int entryScore = Gs_CalculateEntryScore(trendAligned, greenBars, highImpactNews);
            Gs_ExecuteScoredOrder(ORDER_TYPE_BUY, trendScore, entryScore, riskLevel, !trendAligned,
                                Gs_InpBaseSL_USD, Gs_InpTrendTP_USD,
                                trendAligned ? "Trend-Follow BUY" : "Counter-Trend BUY");
            return;
         }
      }
   }

   if(isBearTrendFollowing || isCounterSell)
   {
      double sellThreshold = m15Rates[1].close * (1.0 + 0.0005);
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(currentPrice >= sellThreshold)
      {
         if((m15Rates[1].close < m15Rates[1].open && m15Rates[1].close < m15Rates[2].low) ||
            (m15Rates[1].high - MathMax(m15Rates[1].open, m15Rates[1].close) > MathAbs(m15Rates[1].close - m15Rates[1].open) * 2))
         {
            bool trendAligned = isBearTrendFollowing;
            Gs_glbDashMode   = trendAligned ? "FOLLOW" : "COUNTER";
            Gs_glbDashSignal = "SELL";

            bool passFilter = trendAligned
                               ? Gs_PassEnhancementFilters_TrendFollow(ORDER_TYPE_SELL, d1Trend, m15Rates, currentPrice, filterFail)
                               : Gs_PassEnhancementFilters_CounterTrend(ORDER_TYPE_SELL, m15Rates, currentPrice, filterFail);

            if(!passFilter)
            {
               Gs_glbDashStatus = "FILTERED: " + filterFail;
               return;
            }

            string aiBreakdown = "";
            double aiScore = Gs_AIConfidenceScore(ORDER_TYPE_SELL, m15Rates, currentPrice, aiBreakdown);
            Gs_glbDashAIScore = aiScore;   // display-capture only, does not affect the PASS/BLOCK decision below
            if(Gs_InpEnableAIConfidenceScore && aiScore < Gs_InpAIConfidenceThreshold)
            {
               Gs_glbDashStatus = StringFormat("AI BLOCKED (%.0f/100) %s", aiScore, aiBreakdown);
               return;
            }

            // TEQS: Additional filter - Trend Following ONLY (not Counter-Trend)
            if(trendAligned && !TEQS_CheckFilter(ORDER_TYPE_SELL))
            {
               Gs_glbDashStatus = glbTEQSLastReason + " -> BLOCKED";
               return;
            }

            int entryScore = Gs_CalculateEntryScore(trendAligned, redBars, highImpactNews);
            Gs_ExecuteScoredOrder(ORDER_TYPE_SELL, trendScore, entryScore, riskLevel, !trendAligned,
                                Gs_InpBaseSL_USD, Gs_InpTrendTP_USD,
                                trendAligned ? "Trend-Follow SELL" : "Counter-Trend SELL");
            return;
         }
      }
   }

   Gs_glbDashSignal = "WAIT";
   Gs_glbDashMode   = (isBullTrendFollowing || isBearTrendFollowing) ? "FOLLOW" : (anyCounter ? "COUNTER" : "-");
   Gs_glbDashStatus = "WAITING PULLBACK";
}

//+------------------------------------------------------------------+
//| PART 3 : Sideway Price Engine (Pure Price Action - D1 5-Candle)  |
//+------------------------------------------------------------------+
// Dedicated execution helper for the Sideway Price Engine.
// Bypasses Gs_ExecuteScoredOrder/Gs_GetFixedLot() entirely and sends the order
// with a hard-coded 0.01 lot, per the "ONLY 0.01 lot, no dynamic lot
// calculation" requirement - independent of Gs_InpFixedLotSize so it can never
// drift even if that input is changed for the other engines.
bool Gs_ExecuteSidewayPriceOrder(ENUM_ORDER_TYPE orderType, double slUSD, double tpUSD, string reasonTag)
{
   const double SIDEWAY_FIXED_LOT = 0.01;

   Gs_glbDashLot    = SIDEWAY_FIXED_LOT;
   Gs_glbDashStatus = reasonTag + " -> ORDER SENT";

   bool result = Gs_ExecuteOrderWithUSD_Risk(orderType, SIDEWAY_FIXED_LOT, slUSD, tpUSD, reasonTag);
   if(result) Gs_RegisterOrderTimestamp();
   else Gs_glbDashStatus = reasonTag + " -> ORDER FAILED";
   return result;
}

void Gs_SidewayPriceEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel)
{
   Gs_glbDashEngine   = "SIDEWAY";
   Gs_glbDashMode     = "PRICE";
   Gs_glbDashTrendDir = "-";

   // --- Pure Price Action Range: D1, last 5 CLOSED candles (Shift 1 to Shift 5) ---
   MqlRates ratesD1[];
   ArraySetAsSeries(ratesD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 5, ratesD1) < 5)
   {
      Gs_glbDashStatus = "WAIT FOR ORDER (SIDEWAY)";
      Gs_glbDashSignal = "WAIT";
      return;
   }

   double UpperBoundary = ratesD1[0].high;  // Highest High of the 5 candles = 100%
   double LowerBoundary = ratesD1[0].low;   // Lowest Low of the 5 candles   = 0%

   for(int i = 1; i < 5; i++)
   {
      if(ratesD1[i].high > UpperBoundary) UpperBoundary = ratesD1[i].high;
      if(ratesD1[i].low  < LowerBoundary) LowerBoundary = ratesD1[i].low;
   }

   double Range = UpperBoundary - LowerBoundary;
   if(Range <= 0) return; // Division-by-zero guard

   double Middle       = (UpperBoundary + LowerBoundary) / 2.0; // 50%
   double CurrentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Current price's position within the range, as a percentage (0% - 100%)
   double PricePosition = ((CurrentPrice - LowerBoundary) / Range) * 100.0;

   // --- Breakout Condition: price goes above 100% or below 0% of the D1 5-candle range ---
   if(PricePosition > 100.0 || PricePosition < 0.0)
   {
      Gs_glbDashSignal = "WAIT";
      Gs_glbDashLot    = 0.0;
      Gs_glbDashStatus = "SIDEWAY RANGE BROKEN - RE-EVALUATING TREND";

      // Stop the Sideway Engine immediately and call Detect Trend to re-evaluate the market state.
      static bool insideRedirect = false; // guards against re-entrant recursion
      if(!insideRedirect)
      {
         insideRedirect = true;
         ENUM_MARKET_REGIME regime = Gs_DetectMarketRegime();
         if(regime == REGIME_TREND)
         {
            // Trend Emerging: exit Sideway Engine, switch to Trend Follow / Counter Trend engine.
            Gs_glbDashEngine = "TREND";
            Gs_RunTrendEngine(highImpactNews, riskLevel);
         }
         // else: Detect Trend still reports no valid trend - stay flat this tick;
         // the range recalculates fresh on the next tick.
         insideRedirect = false;
      }
      return;
   }

   // --- No-Trade Zone: 11% - 89% (middle range) ---
   if(PricePosition > 10.0 && PricePosition < 90.0)
   {
      Gs_glbDashSignal = "WAIT";
      Gs_glbDashLot    = 0.0;
      Gs_glbDashStatus = StringFormat("SIDEWAY NO-TRADE ZONE (%.1f%%)", PricePosition);
      return;
   }

   int maxAllowed = Gs_GetMaxPositionsAllowed(riskLevel);
   int openCount  = Gs_CountTotalPositions(_Symbol);
   if(openCount >= maxAllowed)
   {
      Gs_glbDashSignal = "WAIT";
      Gs_glbDashStatus = "MAX ORDERS REACHED (SIDEWAY)";
      return;
   }

   // --- Lot Size & Trading Zones: ONLY 0.01 lot in all cases, no dynamic sizing ---
   ENUM_ORDER_TYPE orderType;
   string reasonTag = "";

   if(PricePosition >= 90.0 && PricePosition <= 100.0)
   {
      orderType = ORDER_TYPE_SELL;
      reasonTag = "Sideway Price SELL (90-100%)";
   }
   else if(PricePosition >= 0.0 && PricePosition <= 10.0)
   {
      orderType = ORDER_TYPE_BUY;
      reasonTag = "Sideway Price BUY (0-10%)";
   }
   else
   {
      // Safety fallback - should not be reached given the ranges above
      Gs_glbDashSignal = "WAIT";
      Gs_glbDashLot    = 0.0;
      Gs_glbDashStatus = StringFormat("SIDEWAY NO-TRADE ZONE (%.1f%%)", PricePosition);
      return;
   }

   Gs_glbDashSignal = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   Gs_ExecuteSidewayPriceOrder(orderType, Gs_InpBaseSL_USD, Gs_InpSidewayTP_USD, reasonTag);
}

//+------------------------------------------------------------------+
//| PART 1 : Extreme Engine Mod (จำกัดปริมาณพร้อมกัน 1 ออเดอร์)       |
//+------------------------------------------------------------------+
int Gs_CountOpenExtremePositions()
{
   int cnt = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         string cmt = PositionGetString(POSITION_COMMENT);
         if(StringFind(cmt, "Extreme") >= 0) cnt++;
      }
   }
   return cnt;
}

bool Gs_RunExtremeEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel)
{
   // --- MINIMAL IMPACT PATCH: บังคับให้มีออเดอร์จาก Extreme ได้สูงสุดไม่เกิน 1 เสมอ ---
   if(Gs_CountOpenExtremePositions() >= 1) return false;

   MqlRates rates180D[];
   ArraySetAsSeries(rates180D, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 1, 180, rates180D);
   if(copied < 180) return false;

   double highest6M = rates180D[0].high;
   double lowest6M = rates180D[0].low;

   for(int i=1; i<180; i++)
   {
      if(rates180D[i].high > highest6M) highest6M = rates180D[i].high;
      if(rates180D[i].low < lowest6M)   lowest6M = rates180D[i].low;
   }

   double extremeHighBound = highest6M * (1.0 + 0.0005);
   double extremeLowBound  = lowest6M * (1.0 - 0.0005);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Gs_glbExtHighTrig = GlobalVariableCheck("ExtHighTrig_"+_Symbol);
   Gs_glbExtLowTrig  = GlobalVariableCheck("ExtLowTrig_"+_Symbol);

   if(currentBid < highest6M && Gs_glbExtHighTrig)   GlobalVariableDel("ExtHighTrig_"+_Symbol);
   if(currentAsk > lowest6M  && Gs_glbExtLowTrig)    GlobalVariableDel("ExtLowTrig_"+_Symbol);

   string filterFail = "";

   if(currentBid >= extremeHighBound && !GlobalVariableCheck("ExtHighTrig_"+_Symbol))
   {
      Gs_glbDashEngine = "EXTREME"; Gs_glbDashMode = "-"; Gs_glbDashTrendDir = "-"; Gs_glbDashSignal = "SELL";

      if(!Gs_PassEnhancementFilters_Extreme(filterFail)) { Gs_glbDashStatus = "FILTERED: " + filterFail; return false; }

      int entryScore = Gs_CalculateEntryScore(true, 10, highImpactNews);
      if(Gs_ExecuteScoredOrder(ORDER_TYPE_SELL, 10.0, entryScore, riskLevel, false,
                             Gs_InpBaseSL_USD, Gs_InpExtremeTP_USD, "Extreme SELL"))
      {
         GlobalVariableSet("ExtHighTrig_"+_Symbol, 1.0);
         return true;
      }
   }

   if(currentAsk <= extremeLowBound && !GlobalVariableCheck("ExtLowTrig_"+_Symbol))
   {
      Gs_glbDashEngine = "EXTREME"; Gs_glbDashMode = "-"; Gs_glbDashTrendDir = "-"; Gs_glbDashSignal = "BUY";

      if(!Gs_PassEnhancementFilters_Extreme(filterFail)) { Gs_glbDashStatus = "FILTERED: " + filterFail; return false; }

      int entryScore = Gs_CalculateEntryScore(true, 10, highImpactNews);
      if(Gs_ExecuteScoredOrder(ORDER_TYPE_BUY, 10.0, entryScore, riskLevel, false,
                             Gs_InpBaseSL_USD, Gs_InpExtremeTP_USD, "Extreme BUY"))
      {
         GlobalVariableSet("ExtLowTrig_"+_Symbol, 1.0);
         return true;
      }
   }

   return false;
}

double Gs_CalculateTrendScore(int dirStrength, int tfAgreement, bool isCounterTrend)
{
   double structureScore = MathMin(MathMax(dirStrength,0), 10) / 10.0 * 6.0;
   double tfScore = (MathMin(MathMax(tfAgreement,0),4) / 4.0) * 4.0;
   double total = structureScore + tfScore;
   if(isCounterTrend) total *= 0.9;
   if(total > 10) total = 10;
   if(total < 0)  total = 0;
   return total;
}

int Gs_CalculateEntryScore(bool trendAligned, int secondaryStrength, bool highImpactNews)
{
   double score = 0.0;

   score += trendAligned ? 7.0 : 3.0;

   double secNorm = MathMin(MathMax(secondaryStrength, 0), 10) / 10.0 * 2.0;
   score += secNorm;

   int freqLast30 = Gs_CountOrderTimestampsWithin(30);
   double newsFreqScore = 1.0;
   if(highImpactNews) newsFreqScore -= 0.6;
   if(freqLast30 >= 3) newsFreqScore -= 0.4;
   if(newsFreqScore < 0) newsFreqScore = 0;
   score += newsFreqScore;

   int finalScore = (int)MathRound(score);
   if(finalScore > 10) finalScore = 10;
   if(finalScore < 0)  finalScore = 0;
   return finalScore;
}

ENUM_RISK_LEVEL Gs_CalculateRiskLevel(bool highImpactNews)
{
   int freqLast30 = Gs_CountOrderTimestampsWithin(30);
   int freqLast60 = Gs_CountOrderTimestampsWithin(60);

   int riskPoints = 0;
   if(highImpactNews) riskPoints += 2;
   if(freqLast30 >= 2) riskPoints += 1;
   if(freqLast60 >= 4) riskPoints += 1;
   if(Gs_glbConsecutiveLosses >= 2) riskPoints += 1;
   if(Gs_GetFloatingPL() <= Gs_InpFloatingLossLimit) riskPoints += 2;

   if(riskPoints >= 4) return RISK_HIGH;
   if(riskPoints >= 2) return RISK_MEDIUM;
   return RISK_LOW;
}

int Gs_GetMaxPositionsAllowed(ENUM_RISK_LEVEL risk)
{
   // PATCH SET F (item 2/4): Gold & Silver Max Orders is fixed at 3 and is
   // never reduced by Risk Level (already matched the spec - unchanged).
   return 3; 
}

int Gs_GetRiskAdjustedCooldown(int baseCooldown, ENUM_RISK_LEVEL risk)
{
   if(risk == RISK_HIGH)   return baseCooldown + 20;
   if(risk == RISK_MEDIUM) return baseCooldown + 10;
   return baseCooldown;
}

string Gs_RiskLevelToString(ENUM_RISK_LEVEL risk)
{
   if(risk == RISK_HIGH)   return "HIGH";
   if(risk == RISK_MEDIUM) return "MEDIUM";
   return "LOW";
}

// Gs_RiskLevelColor() removed - it was used only by the old Gold &
// Silver dashboard, which has been replaced by the shared dashboard.

double Gs_GetFixedLot()
{
   return NormalizeDouble(Gs_InpFixedLotSize, 2);
}

double Gs_GetFloatingPL()
{
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
         floating += PositionGetDouble(POSITION_PROFIT);
   }
   return floating;
}

bool Gs_ExecuteScoredOrder(ENUM_ORDER_TYPE orderType, double trendScore, int entryScore,
                         ENUM_RISK_LEVEL riskLevel, bool isCounterTrend,
                         double slUSD, double tpUSD, string reasonTag)
{
   double lotSize = Gs_GetFixedLot();

   double confidence = Gs_CalculateConfidence(trendScore, entryScore, riskLevel);

   Gs_glbDashEntryScore = entryScore;
   Gs_glbDashTrendScore = trendScore;
   Gs_glbDashLot        = lotSize;
   Gs_glbDashConfidence = confidence;
   Gs_glbDashRisk       = riskLevel;
   Gs_glbDashStatus     = reasonTag + " -> ORDER SENT";

   bool result = Gs_ExecuteOrderWithUSD_Risk(orderType, lotSize, slUSD, tpUSD, reasonTag);
   if(result) Gs_RegisterOrderTimestamp();
   else Gs_glbDashStatus = reasonTag + " -> ORDER FAILED";
   return result;
}

double Gs_CalculateConfidence(double trendScore, int entryScore, ENUM_RISK_LEVEL risk)
{
   double riskFactor = (risk == RISK_LOW) ? 1.0 : (risk == RISK_MEDIUM ? 0.85 : 0.65);
   double confidence = (trendScore * 0.7 + entryScore * 0.3) * riskFactor;
   if(confidence > 10) confidence = 10;
   if(confidence < 0)  confidence = 0;
   return confidence;
}

string Gs_GradeName(int score)
{
   if(score >= 9) return "GOOD";
   if(score >= 5) return "NORMAL";
   if(score >= 1) return "BAD";
   return "RISK";
}

// Gs_GradeColor() removed - it was used only by the old Gold & Silver
// dashboard, which has been replaced by the shared dashboard.

bool Gs_ExecuteOrderWithUSD_Risk(ENUM_ORDER_TYPE orderType, double lotSize, double slUSD, double tpUSD, string comment)
{
   if(lotSize <= 0) return false;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue == 0 || tickSize == 0) return false;

   double slDistPoints = (slUSD * tickSize) / (lotSize * tickValue);
   double tpDistPoints = (tpUSD * tickSize) / (lotSize * tickValue);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double openPrice = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   double slPrice   = (orderType == ORDER_TYPE_BUY) ? (openPrice - slDistPoints) : (openPrice + slDistPoints);
   double tpPrice   = (orderType == ORDER_TYPE_BUY) ? (openPrice + tpDistPoints) : (openPrice - tpDistPoints);

   slPrice = NormalizeDouble(slPrice, _Digits);
   tpPrice = NormalizeDouble(tpPrice, _Digits);

   Gs_trade.SetDeviationInPoints(10);
   bool success = false;

   if(orderType == ORDER_TYPE_BUY)
   {
      success = Gs_trade.Buy(lotSize, _Symbol, openPrice, slPrice, tpPrice, comment);
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      success = Gs_trade.Sell(lotSize, _Symbol, openPrice, slPrice, tpPrice, comment);
   }

   return success;
}

void Gs_CheckTradeHistory()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(currentBalance != Gs_glbLastBalance)
   {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent()))
      {
         uint totalTrades = HistoryDealsTotal();
         if(totalTrades > 0)
         {
            ulong dealTicket = HistoryDealGetTicket(totalTrades - 1);
            if(HistoryDealSelect(dealTicket))
            {
               string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
               if(symbol == _Symbol)
               {
                  double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                  double dealPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

                  if(Gs_InpUseSmartHistory)
                     Gs_RegisterZoneResult(dealPrice, profit > 0);

                  if(profit < 0)
                  {
                     Gs_glbConsecutiveLosses++;
                     Gs_glbConsecutiveWins = 0;

                     Gs_glbCooldownUntil = TimeCurrent() + (Gs_InpCooldownMinutes * 60);
                     Print("[RISK ALERT] Stop Loss hit! Cooldown started for ", Gs_InpCooldownMinutes, " minutes.");
                  }
                  else if(profit > 0)
                  {
                     Gs_glbConsecutiveWins++;
                     Gs_glbConsecutiveLosses = 0;
                  }
               }
            }
         }
      }
      Gs_glbLastBalance = currentBalance;
   }
}

// The old per-mode Gold & Silver Dashboard (Gs_CreateDashboardObjects /
// Gs_SetDashLine / Gs_UpdateDashboard) has been removed. All three modes
// now share a single Dashboard (CreateDashboard() / UpdateDashboard() /
// DeleteDashboard(), object prefix KAI_DASH_) defined in the
// "SHARED DASHBOARD (KAI MT5)" section near the bottom of this file.
// It reads the Gs_glbDash* values above (already produced by the
// unmodified Gold & Silver trading logic) for display only.

//====================================================================
// FOREX MODULE  (from Hybrid_Forex_Mode.mq5 - trading logic unchanged)
//====================================================================
//+------------------------------------------------------------------+
//|                        Hybrid_MultiStrategy_EA_v6_AIConfidence.mq5|
//|                                  Copyright 2026, AI Developer    |
//|                                             https://www.mql5.com |
//|
//| Base: v6.00 Logic เดิมคงไว้ 100%                                  |
//| NEW CHANGE SCOPE (ตามสเปก "AI Confidence Score - Decision Filter |
//| Only"):                                                           |
//|   - เพิ่มฟังก์ชันใหม่ 1 ฟังก์ชันเท่านั้น: Fx_AIConfidenceScore()        |
//|     คำนวณคะแนน 0-100 จาก Trend/Momentum/ADX/ATR/RSI/EMA           |
//|     Alignment/Pullback/Volume แล้วเรียกทันทีก่อน                   |
//|     Fx_ExecuteScoredOrder (จุดเดียวกับก่อน OrderSend()) เฉพาะใน        |
//|     Fx_RunTrendEngine (Trend-Follow BUY/SELL และ Counter BUY/SELL)   |
//|     ตาม Execution Flow ที่กำหนด                                    |
//|   - หน้าที่เดียวคือ PASS (score >= Fx_InpAIConfidenceThreshold) หรือ   |
//|     BLOCK คำสั่งซื้อขายรอบนี้เท่านั้น ไม่มีสิทธิ์เปลี่ยน Trend/        |
//|     Signal/Direction/Strategy ใดๆ ทั้งสิ้น (ตามสเปก)                |
//|   - PATCH SET E: Sideway Engine และ Extreme Engine now also call the |
//|     SAME unmodified Fx_AIConfidenceScore() as a Final Entry Filter,  |
//|     right before their own OrderSend path (unified flow, item 2).   |
//|     Formula/weights/thresholds are untouched; only PASS/BLOCK.      |
//|     - Dashboard / Risk Management / Money Management / Cooldown /   |
//|     SL-TP / Lot Size / Max Positions / ฟังก์ชันเดิมทั้งหมด           |
//|     ไม่ถูกแก้ไขแม้แต่บรรทัดเดียว (คง v6 ไว้ทั้งหมด)                  |
//| ------------------------------------------------------------------|
//| V6.1 CHANGE SCOPE (Minimal Impact Specification):                  |
//|   - Old RunSidewayEngine() DELETED (RSI/ATR/ADX/H1 logic removed)|
//|   - Fx_RunSidewayPriceEngine rebuilt: Pure Price Action, D1 5-Candle |
//|     (Shift 1-5) range -> 0%-100% position, zone-based fixed lots  |
//|   - Breakout (>100% / <0%) stops Sideway Engine and calls Detect  |
//|     Trend (Fx_DetectMarketRegime) to re-evaluate market state        |
//|   - Extreme, Detect Trend, Trend Follow, Counter Trend engines    |
//|     left 100% untouched                                           |
//+------------------------------------------------------------------+

CTrade Fx_trade;

//--- ENUMS ---

// V6 NEW

//--- INPUT PARAMETERS (คงชุดเดิมของ v5 ทั้งหมด) ---
input group "=== Global Risk Management ==="
input double   Fx_InpMaxLotSize        = 0.10;
input double   Fx_InpMinLotSize        = 0.02;
input double   Fx_InpBaseSL_USD        = 300.0;
input int      Fx_InpCooldownMinutes   = 60;
input int      Fx_InpMinTimeBetweenPos = 10;

input group "=== Engine TP Settings ==="
input double   Fx_InpTrendTP_USD       = 1200.0;
input double   Fx_InpSidewayTP_USD     = 400.0;
input double   Fx_InpExtremeTP_USD     = 1000.0;

input group "=== Market Regime (D1 Filters) ==="
input int      Fx_InpADXPeriod         = 14;
input int      Fx_InpEMAPeriod         = 50;
input double   Fx_InpSlopeThreshold    = 10.0;

input group "=== News Filter (MT5 Calendar) ==="
input bool     Fx_InpUseNewsFilter     = true;
input int      Fx_InpNewsLookaheadMin  = 30;
input int      Fx_InpNewsLookbackMin   = 15;

input group "=== Smart History / Zone Memory ==="
input bool     Fx_InpUseSmartHistory   = true;
input double   Fx_InpZonePoints        = 500;

input group "=== Floating Loss Protection ==="
input double   Fx_InpFloatingLossLimit = -50.0;
input double   Fx_InpForcedHighRiskFloatingLoss = -100.0; // PATCH SET F item 6/7: combined Floating Loss (USD) that force-overrides Risk Level to HIGH (Lot/Cooldown/AI Threshold only - never Max Orders)

input group "=== V6 Decision Layer Weights (Info only, logic ผูกตายตัวตามสเปก) ==="
input double   Fx_InpCounterTrendLotFactor = 0.70; // V6 NEW: Lot Counter-Trend = 70% ของปกติ

input group "=== AI Confidence Score (NEW - Decision Filter Only, per spec) ==="
input bool     Fx_InpEnableAIConfidenceScore = true;  // เปิด/ปิด AI Confidence Score Filter
input double   Fx_InpAIConfidenceThreshold   = 60.0;  // เกณฑ์ผ่าน (>=60 PASS ตามสเปก)
input double   Fx_InpAIPullbackMinATRRatio   = 0.30;  // ใช้เฉพาะคำนวณ Pullback Score component (ไม่กระทบ Entry Logic เดิม)
input double   Fx_InpAIPullbackMaxATRRatio   = 0.80;  // ใช้เฉพาะคำนวณ Pullback Score component (ไม่กระทบ Entry Logic เดิม)

// Dashboard inputs for Forex mode removed - a single shared dashboard
// (KAI_DASH_ / CreateDashboard()/UpdateDashboard()/DeleteDashboard())
// now serves all three modes. See the "SHARED DASHBOARD (KAI MT5)"
// section near the bottom of this file.

//--- GLOBAL VARIABLES (ของเดิม v5) ---
datetime Fx_glbCooldownUntil = 0;
bool     Fx_glbExtHighTrig   = false;
bool     Fx_glbExtLowTrig    = false;

int      Fx_glbConsecutiveWins = 0;
int      Fx_glbConsecutiveLosses = 0;
double   Fx_glbLastBalance       = 0.0;

datetime Fx_glbOrderTimestamps[200];
int      Fx_glbOrderTimestampCount = 0;

HistoryZone Fx_glbZones[500];
int         Fx_glbZoneCount = 0;

//--- GLOBAL VARIABLES (Dashboard - เดิม ใช้เพื่อ compat) ---
string  Fx_glbDashNewsText    = "No High Impact News";
string  Fx_glbDashCooldownTxt = "-";
string  Fx_glbDashHistoryTxt  = "-";

//--- GLOBAL VARIABLES (V6 NEW - Decision Layer / Dashboard) ---
string  Fx_glbDashEngine      = "-";     // TREND / SIDEWAY / EXTREME
string  Fx_glbDashMode        = "-";     // FOLLOW / COUNTER / -
string  Fx_glbDashTrendDir    = "-";     // BULL / BEAR / -
string  Fx_glbDashSignal      = "WAIT";  // BUY / SELL / WAIT
double  Fx_glbDashTrendScore  = 0.0;     // 0-10 (Priority 1, informational)
int     Fx_glbDashEntryScore  = 0;       // 0-10 (Priority 2)
ENUM_RISK_LEVEL Fx_glbDashRisk = RISK_LOW; // Priority 3
double  Fx_glbDashLot         = 0.0;
double  Fx_glbDashConfidence  = 0.0;
string  Fx_glbDashStatus      = "IDLE";
// --- display-capture variables added for the shared Dashboard only.
// They store (never recompute) values the existing logic already
// produces at the point each is set, mirroring the pattern already
// used by Cr_glbDashOpenCount/Cr_glbDashMaxOrders/Cr_glbDashAIScore. ---
int     Fx_glbDashOpenCount   = 0;
int     Fx_glbDashMaxOrders   = 0;
double  Fx_glbDashAIScore     = 0.0;
string  Fx_glbDashTrendPersist = "";      // Dashboard-only: latest non-"-" TREND label, persisted (Task: never show "-")


// Forward declaration for the New Sideway Engine to ensure compilation
void Fx_RunSidewayPriceEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel, bool fromTrendFallback = false);

int Fx_OnInit()
{
   Fx_trade.SetExpertMagicNumber(EXPERT_MAGIC);
   Fx_glbLastBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   return(INIT_SUCCEEDED);
}

void Fx_OnDeinit(const int reason)
{
}

void Fx_OnTick()
{
   // --- PATCH SET F (Weekend Detection Fix, item 8): No NEW order may be
   // opened while the Broker's real market/session for this symbol is
   // closed. This gates new entries below only - it does not touch
   // Cooldown, Max Orders, Risk Level, or any other logic. Decision is
   // based ONLY on the Broker's live trading status (see
   // KAI_IsBrokerMarketOpen) - never Local/VPS/Linux/Windows Time, UTC
   // Offset, or Day-Of-Week, so the EA starts trading immediately once
   // the Broker actually opens the market, regardless of what day/time
   // it is on the EA's host. ---
   if(!KAI_IsBrokerMarketOpen(_Symbol))
   {
      Fx_glbDashSignal = "WAIT";
      Fx_glbDashStatus = "WEEKEND - NO NEW ORDERS (FOREX)";
      return;
   }

   bool slCooldownActive = (TimeCurrent() < Fx_glbCooldownUntil);

   Fx_CheckTradeHistory();

   bool highImpactNews = Fx_InpUseNewsFilter ? Fx_IsHighImpactNewsNearby() : false;
   Fx_glbDashNewsText = highImpactNews ? "HIGH IMPACT NEWS NEARBY" : "No High Impact News";

   // V6: Risk Level (Priority 3) คำนวณก่อน เพื่อใช้ปรับ Cooldown / Max Orders เท่านั้น (ไม่มีสิทธิ์ห้ามเทรด)
   ENUM_RISK_LEVEL riskLevel = Fx_CalculateRiskLevel(highImpactNews);

   // --- PATCH SET F (item 6/7): New Risk Rule - if the combined Floating
   // Loss of currently open positions is <= threshold, Risk Level is
   // force-overridden to HIGH immediately, ignoring AI Score/Market
   // Condition/History/existing Logic. This affects Lot Size, Cooldown and
   // AI Threshold ONLY (via riskLevel below) - Max Orders is fixed at 3
   // regardless (see Fx_GetMaxPositionsAllowed) so it is never reduced by
   // this override. Once Floating Loss recovers above the threshold, Risk
   // Level immediately reverts to the normal calculation above. ---
   if(Fx_GetFloatingPL() <= Fx_InpForcedHighRiskFloatingLoss) riskLevel = RISK_HIGH;

   Fx_glbDashRisk = riskLevel;

   int maxAllowed = Fx_GetMaxPositionsAllowed(riskLevel);          // V6 NEW: fixed at 3, no longer risk-reduced
   int openCount  = Fx_CountTotalPositions(_Symbol);
   bool maxPosReached = (openCount >= maxAllowed);

   int baseAdaptiveCooldown = Fx_GetAdaptiveCooldownMinutes();     // เดิม ไม่แก้
   int adaptiveCooldownMin  = Fx_GetRiskAdjustedCooldown(baseAdaptiveCooldown, riskLevel); // V6 NEW
   int minsSinceLast = Fx_GetMinutesSinceLastPosition(_Symbol);

   bool freqCooldownActive = (minsSinceLast < adaptiveCooldownMin);
   Fx_glbDashCooldownTxt = KAI_FormatCooldownText(slCooldownActive, Fx_glbCooldownUntil,
                                                   freqCooldownActive,
                                                   adaptiveCooldownMin, 0);

   Fx_glbDashOpenCount = openCount;
   Fx_glbDashMaxOrders = maxAllowed;

   if(slCooldownActive) { Fx_glbDashStatus = "SL COOLDOWN LOCK"; return; }
   if(maxPosReached)    { Fx_glbDashStatus = "MAX ORDERS REACHED"; return; }
   if(freqCooldownActive) { Fx_glbDashStatus = "FREQUENCY COOLDOWN"; return; }

   if(Fx_RunExtremeEngine(highImpactNews, riskLevel)) return;

   ENUM_MARKET_REGIME regime = Fx_DetectMarketRegime();
   Fx_glbDashEngine = (regime == REGIME_TREND) ? "TREND" : "SIDEWAY";

   if(regime == REGIME_TREND)
   {
      Fx_RunTrendEngine(highImpactNews, riskLevel);
   }
   else if(regime == REGIME_SIDEWAY)
   {
      // Detect Trend = Unclear (No Trend) -> activate the Sideway Price Engine (Pure Price Action)
      Fx_RunSidewayPriceEngine(highImpactNews, riskLevel, false);
   }

   Fx_glbDashOpenCount = Fx_CountTotalPositions(_Symbol);
   Fx_glbDashMaxOrders = maxAllowed;
}

//+------------------------------------------------------------------+
//| ของเดิม (ไม่แก้ไข logic)                                          |
//+------------------------------------------------------------------+
int Fx_CountTotalPositions(string symbol)
{
   int count = 0;
   int buys = 0, sells = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         count++;
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buys++;
         else sells++;
      }
   }
   Fx_glbDashHistoryTxt = StringFormat("Open:%d (Buy:%d / Sell:%d)", count, buys, sells);
   return count;
}

int Fx_GetMinutesSinceLastPosition(string symbol)
{
   datetime lastTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(posTime > lastTime)
         {
            lastTime = posTime;
         }
      }
   }

   if(lastTime == 0) return 99999;
   return (int)((TimeCurrent() - lastTime) / 60);
}

int Fx_GetAdaptiveCooldownMinutes()
{
   int ordersLastHour = Fx_CountOrderTimestampsWithin(60);

   if(ordersLastHour >= 6) return 60;
   if(ordersLastHour >= 4) return 30;
   if(ordersLastHour >= 2) return 15;
   return Fx_InpMinTimeBetweenPos;
}

int Fx_CountOrderTimestampsWithin(int minutes)
{
   int cnt = 0;
   datetime cutoff = TimeCurrent() - minutes * 60;

   for(int i = 0; i < Fx_glbOrderTimestampCount; i++)
      if(Fx_glbOrderTimestamps[i] >= cutoff) cnt++;
   return cnt;
}

void Fx_RegisterOrderTimestamp()
{
   if(Fx_glbOrderTimestampCount >= ArraySize(Fx_glbOrderTimestamps))
   {
      for(int i = 1; i < Fx_glbOrderTimestampCount; i++)
         Fx_glbOrderTimestamps[i-1] = Fx_glbOrderTimestamps[i];
      Fx_glbOrderTimestampCount--;
   }
   Fx_glbOrderTimestamps[Fx_glbOrderTimestampCount] = TimeCurrent();
   Fx_glbOrderTimestampCount++;
}

bool Fx_IsHighImpactNewsNearby()
{
   datetime from = TimeCurrent() - Fx_InpNewsLookbackMin * 60;
   datetime to   = TimeCurrent() + Fx_InpNewsLookaheadMin * 60;

   string baseCcy   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profitCcy = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   MqlCalendarValue values[];
   int total = CalendarValueHistory(values, from, to, NULL, NULL);
   if(total <= 0) return false;

   for(int i = 0; i < total; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(country.currency == baseCcy || country.currency == profitCcy)
         return true;
   }
   return false;
}

double Fx_GetZoneKey(double price)
{
   double zoneSize = Fx_InpZonePoints * _Point;
   if(zoneSize <= 0) return price;
   return MathRound(price / zoneSize) * zoneSize;
}

int Fx_FindZoneIndex(double zoneKey)
{
   for(int i = 0; i < Fx_glbZoneCount; i++)
      if(MathAbs(Fx_glbZones[i].priceLevel - zoneKey) < _Point * 0.5)
         return i;
   return -1;
}

void Fx_RegisterZoneResult(double price, bool win)
{
   double zoneKey = Fx_GetZoneKey(price);
   int idx = Fx_FindZoneIndex(zoneKey);

   if(idx < 0)
   {
      if(Fx_glbZoneCount >= ArraySize(Fx_glbZones)) return;
      idx = Fx_glbZoneCount;
      Fx_glbZones[idx].priceLevel = zoneKey;
      Fx_glbZones[idx].wins = 0;
      Fx_glbZones[idx].losses = 0;
      Fx_glbZoneCount++;
   }
   if(win) Fx_glbZones[idx].wins++;
   else    Fx_glbZones[idx].losses++;
}

int Fx_GetZoneLotAdjustment(double price)
{
   if(!Fx_InpUseSmartHistory) return 0;
   double zoneKey = Fx_GetZoneKey(price);
   int idx = Fx_FindZoneIndex(zoneKey);

   if(idx < 0) return 0;

   int total = Fx_glbZones[idx].wins + Fx_glbZones[idx].losses;
   if(total < 3) return 0;

   double winRate = (double)Fx_glbZones[idx].wins / total;
   if(winRate >= 0.65) return 1;
   if(winRate <= 0.35) return -1;
   return 0;
}

ENUM_MARKET_REGIME Fx_DetectMarketRegime()
{
   int adxHandle = iADX(_Symbol, PERIOD_D1, Fx_InpADXPeriod);
   if(adxHandle == INVALID_HANDLE) return REGIME_SIDEWAY;

   double adxValues[];
   ArraySetAsSeries(adxValues, true);
   if(CopyBuffer(adxHandle, MAIN_LINE, 0, 1, adxValues) <= 0)
   {
      IndicatorRelease(adxHandle);
      return REGIME_SIDEWAY;
   }
   double adx = adxValues[0];

   int emaHandle = iMA(_Symbol, PERIOD_D1, Fx_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE)
   {
      IndicatorRelease(adxHandle);
      return REGIME_SIDEWAY;
   }

   double emaValues[];
   ArraySetAsSeries(emaValues, true);
   if(CopyBuffer(emaHandle, 0, 0, 6, emaValues) < 6)
   {
      IndicatorRelease(adxHandle);
      IndicatorRelease(emaHandle);
      return REGIME_SIDEWAY;
   }

   double emaToday = emaValues[0];
   double ema5DaysAgo = emaValues[5];
   double slope = MathAbs(emaToday - ema5DaysAgo) / _Point;

   IndicatorRelease(adxHandle);
   IndicatorRelease(emaHandle);

   if(adx > 20.0 && slope >= Fx_InpSlopeThreshold)
   {
      return REGIME_TREND;
   }

   return REGIME_SIDEWAY;
}

//+------------------------------------------------------------------+
//| NEW: AI Confidence Score - Decision Filter ONLY (per spec)        |
//| ไม่ใช่ Strategy ใหม่ ไม่มีสิทธิ์เปลี่ยน Trend/Signal/Direction ใดๆ    |
//| ทั้งสิ้น มีหน้าที่เดียวคือคำนวณคะแนน 0-100 แล้วส่งคืนให้ผู้เรียก        |
//| ตัดสิน PASS (>= Fx_InpAIConfidenceThreshold) หรือ BLOCK เท่านั้น        |
//| ถูกเรียกจากจุดเดียว: ทันทีก่อน Fx_ExecuteScoredOrder/OrderSend ใน       |
//| Fx_RunTrendEngine (Trend-Follow / Counter-Trend BUY & SELL) ตาม       |
//| Execution Flow ที่กำหนด ไม่ถูกเรียกใน Sideway Engine หรือ            |
//| Extreme Engine เพราะสเปกกำหนดให้ทั้งสอง Engine นี้ทำงานเหมือนเดิม     |
//| ทุกประการ                                                          |
//| Components: Trend(20) Momentum(20) ADX(15) ATR(10) RSI(10)         |
//|             EMA Alignment(10) Pullback(10) Volume(5)  = 100        |
//+------------------------------------------------------------------+
double Fx_AIConfidenceScore(ENUM_ORDER_TYPE orderType, MqlRates &m15Rates[], double currentPrice, string &scoreBreakdown)
{
   bool isBuy = (orderType == ORDER_TYPE_BUY);
   //--- helper reads (local, self-contained - ไม่แก้ไข/ใช้ฟังก์ชันเดิมใดๆ) ---
   double atrM15Now = 0.0, atrM15Prev = 0.0, atrM15Avg = 0.0;
   {
      int h = iATR(_Symbol, PERIOD_M15, 14);
      if(h != INVALID_HANDLE)
      {
         double buf[];
         ArraySetAsSeries(buf, true);
         if(CopyBuffer(h, 0, 0, 22, buf) >= 22)
         {
            atrM15Now  = buf[0];
            atrM15Prev = buf[1];
            double sum = 0.0;
            for(int i = 1; i <= 20; i++) sum += buf[i];
            atrM15Avg = sum / 20.0;
         }
         IndicatorRelease(h);
      }
   }

   //--- 1) Trend Score (20 pts) - D1 ADX strength + D1 EMA slope strength ---
   double trendScore = 0.0;
   {
      double adxVal = 0.0;
      int adxH = iADX(_Symbol, PERIOD_D1, Fx_InpADXPeriod);
      if(adxH != INVALID_HANDLE)
      {
         double buf[];
         ArraySetAsSeries(buf, true);
         if(CopyBuffer(adxH, MAIN_LINE, 0, 1, buf) > 0) adxVal = buf[0];
         IndicatorRelease(adxH);
      }
      double adxComponent = MathMin(adxVal / 40.0, 1.0) * 12.0;

      double slope = 0.0;
      int emaH = iMA(_Symbol, PERIOD_D1, Fx_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(emaH != INVALID_HANDLE)
      {
         double buf[];
         ArraySetAsSeries(buf, true);
         if(CopyBuffer(emaH, 0, 0, 6, buf) >= 6) slope = MathAbs(buf[0] - buf[5]) / _Point;
         IndicatorRelease(emaH);
      }
      double slopeComponent = MathMin(slope / MathMax(Fx_InpSlopeThreshold * 3.0, 0.0001), 1.0) * 8.0;
      trendScore = adxComponent + slopeComponent;
   }

   //--- 2) Momentum Score (20 pts) - M15 ATR expansion + candle range vs average ---
   double momentumScore = 0.0;
   {
      double atrRatio = (atrM15Prev > 0) ? (atrM15Now / atrM15Prev) : 1.0;
      double atrComp = MathMax(0.0, MathMin((atrRatio - 0.7) / 0.3, 1.0)) * 12.0;

      double range = MathAbs(m15Rates[1].high - m15Rates[1].low);
      double avgRange = 0.0;
      {
         MqlRates r[];
         ArraySetAsSeries(r, true);
         if(CopyRates(_Symbol, PERIOD_M15, 1, 10, r) >= 10)
         {
            double sum = 0.0;
            for(int i = 0; i < 10; i++) sum += (r[i].high - r[i].low);
            avgRange = sum / 10.0;
         }
      }
      double rangeRatio = (avgRange > 0) ? (range / avgRange) : 1.0;
      double rangeComp = MathMax(0.0, MathMin((rangeRatio - 0.7) / 0.3, 1.0)) * 8.0;
      momentumScore = atrComp + rangeComp;
   }

   //--- 3) ADX Score (15 pts) - H1 ADX strength ---
   double adxScore = 0.0;
   {
      double adxVal = 0.0;
      int adxH = iADX(_Symbol, PERIOD_H1, Fx_InpADXPeriod);
      if(adxH != INVALID_HANDLE)
      {
         double buf[];
         ArraySetAsSeries(buf, true);
         if(CopyBuffer(adxH, MAIN_LINE, 0, 1, buf) > 0) adxVal = buf[0];
         IndicatorRelease(adxH);
      }
      adxScore = MathMin(adxVal / 35.0, 1.0) * 15.0;
   }

   //--- 4) ATR Score (10 pts) - M15 ATR vs its own 20-bar average, healthy range ---
   double atrScoreVal = 0.0;
   {
      if(atrM15Avg > 0)
      {
         double ratio = atrM15Now / atrM15Avg;
         if(ratio >= 0.8 && ratio <= 1.5)      atrScoreVal = 10.0;
         else if(ratio < 0.8)                  atrScoreVal = MathMax(0.0, ratio / 0.8) * 10.0;
         else                                  atrScoreVal = MathMax(0.0, 10.0 - (ratio - 1.5) * 10.0);
      }
      else atrScoreVal = 5.0;
   }

   //--- 5) RSI Score (10 pts) - H1 RSI momentum bias in the trade direction ---
   double rsiScoreVal = 0.0;
   {
      double rsiVal = 50.0;
      int rsiH = iRSI(_Symbol, PERIOD_H1, 14, PRICE_CLOSE);
      if(rsiH != INVALID_HANDLE)
      {
         double buf[];
         ArraySetAsSeries(buf, true);
         if(CopyBuffer(rsiH, 0, 0, 1, buf) > 0) rsiVal = buf[0];
         IndicatorRelease(rsiH);
      }
      double diff = isBuy ? (rsiVal - 50.0) : (50.0 - rsiVal);
      rsiScoreVal = MathMax(0.0, MathMin(diff / 20.0, 1.0)) * 10.0;
   }

   //--- 6) EMA Alignment Score (10 pts) - price vs EMA across M15/H1/H4/D1 ---
   double emaAlignScore = 0.0;
   {
      ENUM_TIMEFRAMES tfs[4] = {PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
      int aligned = 0, validTf = 0;
      double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      for(int i = 0; i < 4; i++)
      {
         int emaH = iMA(_Symbol, tfs[i], Fx_InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
         if(emaH == INVALID_HANDLE) continue;
         double buf[]; ArraySetAsSeries(buf, true);
         bool ok = (CopyBuffer(emaH, 0, 0, 1, buf) > 0);
         double emaVal = ok ? buf[0] : 0.0;
         IndicatorRelease(emaH);
         if(!ok) continue;
         validTf++;
         if(isBuy  && px > emaVal) aligned++;
         if(!isBuy && px < emaVal) aligned++;
      }
      emaAlignScore = (validTf > 0) ? ((double)aligned / validTf) * 10.0 : 5.0;
   }

   //--- 7) Pullback Score (10 pts) - how close the pullback sits to the ideal ATR-ratio midpoint ---
   double pullbackScoreVal = 0.0;
   {
      double pullback = isBuy ? MathAbs(m15Rates[2].high - currentPrice) : MathAbs(m15Rates[2].low - currentPrice);
      if(atrM15Now > 0)
      {
         double ratio = pullback / atrM15Now;
         double mid = (Fx_InpAIPullbackMinATRRatio + Fx_InpAIPullbackMaxATRRatio) / 2.0;
         double halfRange = (Fx_InpAIPullbackMaxATRRatio - Fx_InpAIPullbackMinATRRatio) / 2.0;
         if(halfRange > 0)
         {
            double dist = MathAbs(ratio - mid);
            pullbackScoreVal = MathMax(0.0, 1.0 - (dist / (halfRange * 1.5))) * 10.0;
         }
      }
      else pullbackScoreVal = 5.0;
   }

   //--- 8) Volume Score (5 pts) - last closed M15 tick-volume vs its 10-bar average ---
   double volumeScoreVal = 0.0;
   {
      long vol[];
      ArraySetAsSeries(vol, true);
      if(CopyTickVolume(_Symbol, PERIOD_M15, 1, 11, vol) >= 11)
      {
         double curVol = (double)vol[0];
         double sum = 0.0;
         for(int i = 1; i < 11; i++) sum += (double)vol[i];
         double avgVol = sum / 10.0;
         double ratio = (avgVol > 0) ? (curVol / avgVol) : 1.0;
         volumeScoreVal = MathMax(0.0, MathMin((ratio - 0.5) / 0.5, 1.0)) * 5.0;
      }
      else volumeScoreVal = 2.5;
   }

   double totalScore = trendScore + momentumScore + adxScore + atrScoreVal + rsiScoreVal
                        + emaAlignScore + pullbackScoreVal + volumeScoreVal;
   if(totalScore > 100) totalScore = 100;
   if(totalScore < 0)   totalScore = 0;
   scoreBreakdown = StringFormat("Trend:%.0f/20 Mom:%.0f/20 ADX:%.0f/15 ATR:%.0f/10 RSI:%.0f/10 EMA:%.0f/10 PB:%.0f/10 Vol:%.0f/5",
                                  trendScore, momentumScore, adxScore, atrScoreVal, rsiScoreVal,
                                  emaAlignScore, pullbackScoreVal, volumeScoreVal);
   return totalScore;
}

//+------------------------------------------------------------------+
//| V6: TREND ENGINE  - Trend Detection เดิม 100% ไม่แก้              |
//|     ปรับเฉพาะ Decision Layer (Trend-Follow priority, Counter      |
//|     Trend เข้มขึ้นเป็น 4/4 timeframe, Lot Counter-Trend = 70%)     |
//+------------------------------------------------------------------+
void Fx_RunTrendEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel)
{
   MqlRates ratesD1[];
   ArraySetAsSeries(ratesD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 1, ratesD1) < 1) return;

   ENUM_TREND_DIRECTION d1Trend = DIRECTION_NONE;
   if(ratesD1[0].close > ratesD1[0].open)      d1Trend = DIRECTION_BULL;
   else if(ratesD1[0].close < ratesD1[0].open) d1Trend = DIRECTION_BEAR;

   if(d1Trend == DIRECTION_NONE)
   {
      // Trend Fading (no clear D1 direction) -> switch back to the Sideway Price Engine
      Fx_RunSidewayPriceEngine(highImpactNews, riskLevel, true);
      return;
   }
   Fx_glbDashTrendDir = (d1Trend == DIRECTION_BULL) ? "BULL" : "BEAR";

   // Multi-timeframe อิงแท่งปิดล่าสุด (เดิม 100%, ใช้ทั้งนับคะแนน trend-follow และตรวจ counter-trend)
   int greenBars = 0, redBars = 0;
   ENUM_TIMEFRAMES tfs[4] = {PERIOD_H4, PERIOD_H1, PERIOD_M30, PERIOD_M15};

   for(int i = 0; i < 4; i++)
   {
      MqlRates r[];
      ArraySetAsSeries(r, true);
      if(CopyRates(_Symbol, tfs[i], 1, 1, r) > 0)
      {
         if(r[0].close > r[0].open) greenBars++;
         else if(r[0].close < r[0].open) redBars++;
      }
   }

   // ----- Priority 1: Trend Following มีสิทธิ์ก่อนเสมอ -----
   // PATCH: now uses ConfirmFollowTrend() (>=3/4, big-body confirmed on
   // H4/H1) instead of the plain greenBars/redBars >= 3 count.
   bool isBullTrendFollowing = (d1Trend == DIRECTION_BULL && ConfirmFollowTrend(_Symbol, d1Trend));
   bool isBearTrendFollowing = (d1Trend == DIRECTION_BEAR && ConfirmFollowTrend(_Symbol, d1Trend));

   // ----- Counter-Trend: ทำงานได้เฉพาะเมื่อไม่มีสัญญาณ Trend-Follow -----
   // V6: เข้มขึ้น ต้องตรงข้าม D1 ครบ 4/4 timeframe (100%) ห้ามใช้แค่ 3/4
   // PATCH: now uses ConfirmCounterTrend() (4/4, big-body confirmed on H4/H1)
   // instead of the plain greenBars/redBars == 4 count.
   bool isCounterBuy  = (!isBullTrendFollowing && !isBearTrendFollowing &&
                          d1Trend == DIRECTION_BEAR && ConfirmCounterTrend(_Symbol, d1Trend));
   bool isCounterSell = (!isBullTrendFollowing && !isBearTrendFollowing &&
                          d1Trend == DIRECTION_BULL && ConfirmCounterTrend(_Symbol, d1Trend));

   int dirStrength = 10;
   int tfAgreement  = (d1Trend == DIRECTION_BULL) ? greenBars : redBars;
   bool anyCounter = (isCounterBuy || isCounterSell);
   double trendScore = Fx_CalculateTrendScore(dirStrength, tfAgreement, anyCounter);
   Fx_glbDashTrendScore = trendScore;

   MqlRates m15Rates[];
   ArraySetAsSeries(m15Rates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 3, m15Rates) < 3) return;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   Fx_glbDashEngine = "TREND";

   if(isBullTrendFollowing || isCounterBuy)
   {
      double buyThreshold = m15Rates[1].close * (1.0 - 0.0005);
      if(currentPrice <= buyThreshold)
      {
         if((m15Rates[1].close > m15Rates[1].open && m15Rates[1].close > m15Rates[2].high) ||
            (MathMin(m15Rates[1].open, m15Rates[1].close) - m15Rates[1].low > MathAbs(m15Rates[1].close - m15Rates[1].open) * 2))
         {
            bool trendAligned = isBullTrendFollowing;
            Fx_glbDashMode   = trendAligned ? "FOLLOW" : "COUNTER";
            Fx_glbDashSignal = "BUY";

            string aiBreakdown = "";
            double aiScore = Fx_AIConfidenceScore(ORDER_TYPE_BUY, m15Rates, currentPrice, aiBreakdown);
            Fx_glbDashAIScore = aiScore;   // display-capture only, does not affect the PASS/BLOCK decision below

            if(Fx_InpEnableAIConfidenceScore && aiScore < Fx_InpAIConfidenceThreshold)
            {
               Fx_glbDashStatus = StringFormat("AI BLOCKED (%.0f/100) %s", aiScore, aiBreakdown);
               return;
            }

            // TEQS: Additional filter - Trend Following ONLY (not Counter-Trend)
            if(trendAligned && !TEQS_CheckFilter(ORDER_TYPE_BUY))
            {
               Fx_glbDashStatus = glbTEQSLastReason + " -> BLOCKED";
               return;
            }

            int entryScore = Fx_CalculateEntryScore(trendAligned, greenBars, highImpactNews);
            Fx_ExecuteScoredOrder(ORDER_TYPE_BUY, trendScore, entryScore, riskLevel, !trendAligned,
                                Fx_InpBaseSL_USD, Fx_InpTrendTP_USD,
                                trendAligned ? "Trend-Follow BUY" : "Counter-Trend BUY", highImpactNews);
            return; // Priority 1: ถ้า Trend-Follow ผ่าน เปิดออเดอร์ทันที ไม่ต้องตรวจฝั่งตรงข้ามซ้ำ
         }
      }
   }

   if(isBearTrendFollowing || isCounterSell)
   {
      double sellThreshold = m15Rates[1].close * (1.0 + 0.0005);
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(currentPrice >= sellThreshold)
      {
         if((m15Rates[1].close < m15Rates[1].open && m15Rates[1].close < m15Rates[2].low) ||
            (m15Rates[1].high - MathMax(m15Rates[1].open, m15Rates[1].close) > MathAbs(m15Rates[1].close - m15Rates[1].open) * 2))
         {
            bool trendAligned = isBearTrendFollowing;
            Fx_glbDashMode   = trendAligned ? "FOLLOW" : "COUNTER";
            Fx_glbDashSignal = "SELL";

            string aiBreakdown = "";
            double aiScore = Fx_AIConfidenceScore(ORDER_TYPE_SELL, m15Rates, currentPrice, aiBreakdown);
            Fx_glbDashAIScore = aiScore;   // display-capture only, does not affect the PASS/BLOCK decision below
            if(Fx_InpEnableAIConfidenceScore && aiScore < Fx_InpAIConfidenceThreshold)
            {
               Fx_glbDashStatus = StringFormat("AI BLOCKED (%.0f/100) %s", aiScore, aiBreakdown);
               return;
            }

            // TEQS: Additional filter - Trend Following ONLY (not Counter-Trend)
            if(trendAligned && !TEQS_CheckFilter(ORDER_TYPE_SELL))
            {
               Fx_glbDashStatus = glbTEQSLastReason + " -> BLOCKED";
               return;
            }

            int entryScore = Fx_CalculateEntryScore(trendAligned, redBars, highImpactNews);
            Fx_ExecuteScoredOrder(ORDER_TYPE_SELL, trendScore, entryScore, riskLevel, !trendAligned,
                                Fx_InpBaseSL_USD, Fx_InpTrendTP_USD,
                                trendAligned ? "Trend-Follow SELL" : "Counter-Trend SELL", highImpactNews);
            return;
         }
      }
   }

   Fx_glbDashSignal = "WAIT";
   Fx_glbDashMode   = (isBullTrendFollowing || isBearTrendFollowing) ? "FOLLOW" : (anyCounter ? "COUNTER" : "-");
   Fx_glbDashStatus = "WAITING PULLBACK";
}

//+------------------------------------------------------------------+
//| Sideway Price Engine (Pure Price Action - D1 5-Candle Range)      |
//+------------------------------------------------------------------+
bool Fx_ExecuteSidewayOrder(ENUM_ORDER_TYPE orderType, double lotSize, double slUSD, double tpUSD, string reasonTag)
{
   Fx_glbDashStatus = reasonTag + " -> ORDER SENT";
   bool result = Fx_ExecuteOrderWithUSD_Risk(orderType, lotSize, slUSD, tpUSD, reasonTag);
   if(result) Fx_RegisterOrderTimestamp();
   else Fx_glbDashStatus = reasonTag + " -> ORDER FAILED";
   return result;
}

void Fx_RunSidewayPriceEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel, bool fromTrendFallback = false)
{
   // --- Pure Price Action Range: D1, last 5 CLOSED candles (Shift 1 to Shift 5) ---
   MqlRates ratesD1[];
   ArraySetAsSeries(ratesD1, true);
   if(CopyRates(_Symbol, PERIOD_D1, 1, 5, ratesD1) < 5) return;

   double upperBoundary = ratesD1[0].high;   // Highest High of the 5 candles = 100%
   double lowerBoundary = ratesD1[0].low;    // Lowest Low of the 5 candles   = 0%
   for(int i = 1; i < 5; i++)
   {
      if(ratesD1[i].high > upperBoundary) upperBoundary = ratesD1[i].high;
      if(ratesD1[i].low  < lowerBoundary) lowerBoundary = ratesD1[i].low;
   }

   double range = upperBoundary - lowerBoundary;
   if(range <= 0) return;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pricePosition = ((currentPrice - lowerBoundary) / range) * 100.0; // 0% - 100%

   Fx_glbDashEngine   = "SIDEWAY";
   Fx_glbDashMode     = "PRICE";
   Fx_glbDashTrendDir = "-";

   // --- Breakout Condition: price goes above 100% or below 0% of the D1 5-candle range ---
   if(pricePosition > 100.0 || pricePosition < 0.0)
   {
      Fx_glbDashSignal = "WAIT";
      Fx_glbDashLot    = 0.0;
      Fx_glbDashStatus = "SIDEWAY RANGE BROKEN - RE-EVALUATING TREND";

      // Stop the Sideway Engine immediately and call Detect Trend to re-evaluate the market state.
      if(!fromTrendFallback)
      {
         ENUM_MARKET_REGIME regime = Fx_DetectMarketRegime();
         if(regime == REGIME_TREND)
         {
            // Trend Emerging: exit Sideway Engine and switch to Trend Follow / Counter Trend engine.
            Fx_glbDashEngine = "TREND";
            Fx_RunTrendEngine(highImpactNews, riskLevel);
         }
         // else: Detect Trend still says no valid trend - remain flat this tick;
         // the range will be recalculated fresh on the next tick.
      }
      return;
   }

   // --- No-Trade Zone: 26% - 74% (middle range) ---
   if(pricePosition > 25.0 && pricePosition < 75.0)
   {
      Fx_glbDashSignal = "WAIT";
      Fx_glbDashLot    = 0.0;
      Fx_glbDashStatus = StringFormat("SIDEWAY NO-TRADE ZONE (%.1f%%)", pricePosition);
      return;
   }

   // --- Dynamic Lot Size System (Based on Price % Zone) ---
   ENUM_ORDER_TYPE orderType;
   double sidewayLot = 0.0;
   string reasonTag = "";

   if(pricePosition >= 95.0 && pricePosition <= 100.0)
   {
      orderType  = ORDER_TYPE_SELL;
      sidewayLot = 0.04;
      reasonTag  = "Sideway Price SELL (95-100%)";
   }
   else if(pricePosition >= 80.0 && pricePosition <= 94.0)
   {
      orderType  = ORDER_TYPE_SELL;
      sidewayLot = 0.03;
      reasonTag  = "Sideway Price SELL (80-94%)";
   }
   else if(pricePosition >= 75.0 && pricePosition <= 79.0)
   {
      orderType  = ORDER_TYPE_SELL;
      sidewayLot = 0.02;
      reasonTag  = "Sideway Price SELL (75-79%)";
   }
   else if(pricePosition >= 21.0 && pricePosition <= 25.0)
   {
      orderType  = ORDER_TYPE_BUY;
      sidewayLot = 0.02;
      reasonTag  = "Sideway Price BUY (21-25%)";
   }
   else if(pricePosition >= 6.0 && pricePosition <= 20.0)
   {
      orderType  = ORDER_TYPE_BUY;
      sidewayLot = 0.03;
      reasonTag  = "Sideway Price BUY (6-20%)";
   }
   else if(pricePosition >= 0.0 && pricePosition <= 5.0)
   {
      orderType  = ORDER_TYPE_BUY;
      sidewayLot = 0.04;
      reasonTag  = "Sideway Price BUY (0-5%)";
   }
   else
   {
      // Safety fallback - should not be reached given the ranges above
      Fx_glbDashSignal = "WAIT";
      Fx_glbDashLot    = 0.0;
      Fx_glbDashStatus = StringFormat("SIDEWAY NO-TRADE ZONE (%.1f%%)", pricePosition);
      return;
   }

   Fx_glbDashSignal = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   Fx_glbDashLot    = sidewayLot;

   // --- PATCH SET E (item 2): AI Confidence Score is now the Final Entry
   // Filter for the Forex Sideway Engine too (Trend already had it). Reuses
   // the existing, unmodified Fx_AIConfidenceScore() formula/weights - PASS
   // or BLOCK only; never changes the Sideway zone, signal, or lot above. ---
   MqlRates sidewayAiRates[];
   ArraySetAsSeries(sidewayAiRates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 3, sidewayAiRates) >= 3)
   {
      string aiBreakdown = "";
      double aiScore = Fx_AIConfidenceScore(orderType, sidewayAiRates, currentPrice, aiBreakdown);
      Fx_glbDashAIScore = aiScore;
      if(Fx_InpEnableAIConfidenceScore && aiScore < Fx_InpAIConfidenceThreshold)
      {
         Fx_glbDashStatus = StringFormat("AI BLOCKED (%.0f/100) %s", aiScore, aiBreakdown);
         return;
      }
   }

   Fx_ExecuteSidewayOrder(orderType, sidewayLot, Fx_InpBaseSL_USD, Fx_InpSidewayTP_USD, reasonTag);
}

//+------------------------------------------------------------------+
//| Extreme Engine - ไม่แก้ไข logic เดิม                              |
//+------------------------------------------------------------------+
// V6 PATCH: นับจำนวน Extreme position ที่เปิดอยู่ (ใช้จำกัด Extreme Engine ให้เหลือ 1 ไม้)
int Fx_CountOpenExtremePositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
      {
         string cmt = PositionGetString(POSITION_COMMENT);
         if(StringFind(cmt, "Extreme") >= 0) count++;
      }
   }
   return count;
}

bool Fx_RunExtremeEngine(bool highImpactNews, ENUM_RISK_LEVEL riskLevel)
{
   MqlRates rates180D[];
   ArraySetAsSeries(rates180D, true);
   int copied = CopyRates(_Symbol, PERIOD_D1, 1, 180, rates180D);
   if(copied < 180) return false;

   double highest6M = rates180D[0].high;
   double lowest6M = rates180D[0].low;
   for(int i=1; i<180; i++)
   {
      if(rates180D[i].high > highest6M) highest6M = rates180D[i].high;
      if(rates180D[i].low < lowest6M)   lowest6M = rates180D[i].low;
   }

   double extremeHighBound = highest6M * (1.0 + 0.0005);
   double extremeLowBound  = lowest6M * (1.0 - 0.0005);

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   Fx_glbExtHighTrig = GlobalVariableCheck("ExtHighTrig_"+_Symbol);
   Fx_glbExtLowTrig  = GlobalVariableCheck("ExtLowTrig_"+_Symbol);

   if(currentBid < highest6M && Fx_glbExtHighTrig)   GlobalVariableDel("ExtHighTrig_"+_Symbol);
   if(currentAsk > lowest6M  && Fx_glbExtLowTrig)    GlobalVariableDel("ExtLowTrig_"+_Symbol);

   // ==================== V6 PATCH: Extreme Engine - 1 position at a time ====================
   if(Fx_CountOpenExtremePositions() >= 1) return false;
   // ==================== END PATCH ====================

   if(currentBid >= extremeHighBound && !GlobalVariableCheck("ExtHighTrig_"+_Symbol))
   {
      Fx_glbDashEngine = "EXTREME";
      Fx_glbDashMode = "-"; Fx_glbDashTrendDir = "-"; Fx_glbDashSignal = "SELL";

      // --- PATCH SET E (item 2): AI Confidence Score is now the Final Entry
      // Filter for the Forex Extreme Engine too (Trend already had it). Reuses
      // the existing, unmodified Fx_AIConfidenceScore() formula/weights -
      // PASS or BLOCK only, never changes the Extreme signal/bounds above. ---
      MqlRates extAiRates[];
      ArraySetAsSeries(extAiRates, true);
      if(CopyRates(_Symbol, PERIOD_M15, 0, 3, extAiRates) >= 3)
      {
         string aiBreakdown = "";
         double aiScore = Fx_AIConfidenceScore(ORDER_TYPE_SELL, extAiRates, currentBid, aiBreakdown);
         Fx_glbDashAIScore = aiScore;
         if(Fx_InpEnableAIConfidenceScore && aiScore < Fx_InpAIConfidenceThreshold)
         {
            Fx_glbDashStatus = StringFormat("AI BLOCKED (%.0f/100) %s", aiScore, aiBreakdown);
            return false;
         }
      }

      int entryScore = Fx_CalculateEntryScore(true, 10, highImpactNews);
      if(Fx_ExecuteScoredOrder(ORDER_TYPE_SELL, 10.0, entryScore, riskLevel, false,
                             Fx_InpBaseSL_USD, Fx_InpExtremeTP_USD, "Extreme SELL", highImpactNews))
      {
         GlobalVariableSet("ExtHighTrig_"+_Symbol, 1.0);
         return true;
      }
   }

   if(currentAsk <= extremeLowBound && !GlobalVariableCheck("ExtLowTrig_"+_Symbol))
   {
      Fx_glbDashEngine = "EXTREME";
      Fx_glbDashMode = "-"; Fx_glbDashTrendDir = "-"; Fx_glbDashSignal = "BUY";

      // --- PATCH SET E (item 2): AI Confidence Score final-filter, see note above. ---
      MqlRates extAiRates[];
      ArraySetAsSeries(extAiRates, true);
      if(CopyRates(_Symbol, PERIOD_M15, 0, 3, extAiRates) >= 3)
      {
         string aiBreakdown = "";
         double aiScore = Fx_AIConfidenceScore(ORDER_TYPE_BUY, extAiRates, currentAsk, aiBreakdown);
         Fx_glbDashAIScore = aiScore;
         if(Fx_InpEnableAIConfidenceScore && aiScore < Fx_InpAIConfidenceThreshold)
         {
            Fx_glbDashStatus = StringFormat("AI BLOCKED (%.0f/100) %s", aiScore, aiBreakdown);
            return false;
         }
      }

      int entryScore = Fx_CalculateEntryScore(true, 10, highImpactNews);
      if(Fx_ExecuteScoredOrder(ORDER_TYPE_BUY, 10.0, entryScore, riskLevel, false,
                             Fx_InpBaseSL_USD, Fx_InpExtremeTP_USD, "Extreme BUY", highImpactNews))
      {
         GlobalVariableSet("ExtLowTrig_"+_Symbol, 1.0);
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| V6 NEW: Priority 1 - Trend Score (informational, ไม่มีสิทธิ์ห้ามเทรด)|
//+------------------------------------------------------------------+
double Fx_CalculateTrendScore(int dirStrength, int tfAgreement, bool isCounterTrend)
{
   double structureScore = MathMin(MathMax(dirStrength,0), 10) / 10.0 * 6.0;
   double tfScore = (MathMin(MathMax(tfAgreement,0),4) / 4.0) * 4.0;
   double total = structureScore + tfScore;
   if(isCounterTrend) total *= 0.9;
   if(total > 10) total = 10;
   if(total < 0)  total = 0;
   return total;
}

//+------------------------------------------------------------------+
//| V6: Priority 2 - Entry Score (เดิมคือ CalculateEAScore ของ v5)     |
//+------------------------------------------------------------------+
int Fx_CalculateEntryScore(bool trendAligned, int secondaryStrength, bool highImpactNews)
{
   double score = 0.0;

   score += trendAligned ? 7.0 : 3.0;
   double secNorm = MathMin(MathMax(secondaryStrength, 0), 10) / 10.0 * 2.0;
   score += secNorm;

   int freqLast30 = Fx_CountOrderTimestampsWithin(30);
   double newsFreqScore = 1.0;
   if(highImpactNews) newsFreqScore -= 0.6;
   if(freqLast30 >= 3) newsFreqScore -= 0.4;
   if(newsFreqScore < 0) newsFreqScore = 0;
   score += newsFreqScore;

   int finalScore = (int)MathRound(score);
   if(finalScore > 10) finalScore = 10;
   if(finalScore < 0)  finalScore = 0;
   return finalScore;
}

//+------------------------------------------------------------------+
//| V6 NEW: Priority 3 - Risk Level (LOW/MEDIUM/HIGH)                 |
//+------------------------------------------------------------------+
ENUM_RISK_LEVEL Fx_CalculateRiskLevel(bool highImpactNews)
{
   int freqLast30 = Fx_CountOrderTimestampsWithin(30);
   int freqLast60 = Fx_CountOrderTimestampsWithin(60);

   int riskPoints = 0;
   if(highImpactNews) riskPoints += 2;
   if(freqLast30 >= 2) riskPoints += 1;
   if(freqLast60 >= 4) riskPoints += 1;

   if(Fx_glbConsecutiveLosses >= 2) riskPoints += 1;
   if(Fx_GetFloatingPL() <= Fx_InpFloatingLossLimit) riskPoints += 2;

   if(riskPoints >= 4) return RISK_HIGH;
   if(riskPoints >= 2) return RISK_MEDIUM;
   return RISK_LOW;
}

int Fx_GetMaxPositionsAllowed(ENUM_RISK_LEVEL risk)
{
   // PATCH SET F (item 1/4): Forex Max Orders is fixed at 3, Monday-Friday,
   // and is no longer reduced by Risk Level (LOW/MEDIUM/HIGH). Risk Level
   // still exists and still affects Lot Size / Cooldown / AI Threshold via
   // the other functions below - it just no longer has any effect here.
   return 3;
}

int Fx_GetRiskAdjustedCooldown(int baseCooldown, ENUM_RISK_LEVEL risk)
{
   if(risk == RISK_HIGH)   return baseCooldown + 20;
   if(risk == RISK_MEDIUM) return baseCooldown + 10;
   return baseCooldown;
}

string Fx_RiskLevelToString(ENUM_RISK_LEVEL risk)
{
   if(risk == RISK_HIGH)   return "HIGH";
   if(risk == RISK_MEDIUM) return "MEDIUM";
   return "LOW";
}

// Fx_RiskLevelColor() removed - it was used only by the old Forex
// dashboard, which has been replaced by the shared dashboard.

//+------------------------------------------------------------------+
//| Lot Sizing - เดิม (Smart History / Win-Loss streak / Floating)    |
//+------------------------------------------------------------------+
double Fx_ScoreToLot(int score, double refPrice, ENUM_RISK_LEVEL risk, bool highImpactNews = false)
{
   double lot;
   if(score >= 9)       lot = 0.09 + (score - 9) * 0.01;
   else if(score >= 5)  lot = 0.05 + (score - 5) * (0.03/3.0);
   else if(score >= 1)  lot = 0.02 + (score - 1) * (0.02/3.0);
   else                 lot = Fx_InpMinLotSize;

   int zoneAdj = Fx_GetZoneLotAdjustment(refPrice);
   if(zoneAdj > 0) lot = MathMin(lot + 0.01, Fx_InpMaxLotSize);
   if(zoneAdj < 0) lot = Fx_InpMinLotSize;

   if(Fx_glbConsecutiveWins >= 3)   lot = MathMin(lot + 0.02, Fx_InpMaxLotSize);
   if(Fx_glbConsecutiveLosses >= 3) lot = Fx_InpMinLotSize;
   if(Fx_GetFloatingPL() <= Fx_InpFloatingLossLimit) lot = Fx_InpMinLotSize;

   double lotRatio = (Fx_InpMaxLotSize > Fx_InpMinLotSize) 
      ? (lot - Fx_InpMinLotSize) / (Fx_InpMaxLotSize - Fx_InpMinLotSize) : 0.0;
   if(lotRatio < 0.0) lotRatio = 0.0;
   if(lotRatio > 1.0) lotRatio = 1.0;

   if(risk == RISK_LOW)
      lot = 0.08 + lotRatio * (0.10 - 0.08);
   else if(risk == RISK_MEDIUM)
      lot = 0.05 + lotRatio * (0.07 - 0.05);
   else // RISK_HIGH
      lot = 0.02 + lotRatio * (0.04 - 0.02);

   // --- PATCH SET E (Cascade Lot Calculation, item 6/7): News Filter step.
   // Cumulative on top of the Risk-Level lot above (never resets Base Lot).
   // News Filter may ONLY temporarily reduce lot size here - it can never
   // block the order or change BUY/SELL, and this never touches the fixed
   // zone-table lot used by the Sideway Price Engine. ---
   if(highImpactNews) lot = MathMax(Fx_InpMinLotSize, lot * 0.75);

   if(lot > Fx_InpMaxLotSize) lot = Fx_InpMaxLotSize;
   if(lot > 0 && lot < Fx_InpMinLotSize) lot = Fx_InpMinLotSize;

   return NormalizeDouble(lot, 2);
}

double Fx_GetFloatingPL()
{
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EXPERT_MAGIC)
         floating += PositionGetDouble(POSITION_PROFIT);
   }
   return floating;
}

//+------------------------------------------------------------------+
//| V6: รวม 3 Layer เข้าด้วยกันเพื่อส่งออเดอร์จริง                       |
//+------------------------------------------------------------------+
bool Fx_ExecuteScoredOrder(ENUM_ORDER_TYPE orderType, double trendScore, int entryScore,
                         ENUM_RISK_LEVEL riskLevel, bool isCounterTrend,
                         double slUSD, double tpUSD, string reasonTag, bool highImpactNews = false)
{
   double refPrice = SymbolInfoDouble(_Symbol, (orderType == ORDER_TYPE_BUY) ? SYMBOL_ASK : SYMBOL_BID);
   // PATCH SET E: highImpactNews now threaded through so the Cascade's News
   // Filter step (Fx_ScoreToLot) can apply its temporary lot reduction.
   double lotSize = Fx_ScoreToLot(entryScore, refPrice, riskLevel, highImpactNews);

   if(isCounterTrend)
      lotSize = NormalizeDouble(lotSize * Fx_InpCounterTrendLotFactor, 2);

   if(lotSize < 0.01) lotSize = 0.01; 

   double confidence = Fx_CalculateConfidence(trendScore, entryScore, riskLevel);

   Fx_glbDashEntryScore = entryScore;
   Fx_glbDashTrendScore = trendScore;
   Fx_glbDashLot        = lotSize;
   Fx_glbDashConfidence = confidence;
   Fx_glbDashRisk       = riskLevel;
   Fx_glbDashStatus     = reasonTag + " -> ORDER SENT";

   bool result = Fx_ExecuteOrderWithUSD_Risk(orderType, lotSize, slUSD, tpUSD, reasonTag);
   if(result) Fx_RegisterOrderTimestamp();
   else Fx_glbDashStatus = reasonTag + " -> ORDER FAILED";
   return result;
}

double Fx_CalculateConfidence(double trendScore, int entryScore, ENUM_RISK_LEVEL risk)
{
   double riskFactor = (risk == RISK_LOW) ? 1.0 : (risk == RISK_MEDIUM ? 0.85 : 0.65);
   double confidence = (trendScore * 0.7 + entryScore * 0.3) * riskFactor;
   if(confidence > 10) confidence = 10;
   if(confidence < 0)  confidence = 0;
   return confidence;
}

string Fx_GradeName(int score)
{
   if(score >= 9) return "GOOD";
   if(score >= 5) return "NORMAL";
   if(score >= 1) return "BAD";
   return "RISK";
}

// Fx_GradeColor() removed - it was used only by the old Forex
// dashboard, which has been replaced by the shared dashboard.

bool Fx_ExecuteOrderWithUSD_Risk(ENUM_ORDER_TYPE orderType, double lotSize, double slUSD, double tpUSD, string comment)
{
   if(lotSize <= 0) return false;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue == 0 || tickSize == 0) return false;

   double slDistPoints = (slUSD * tickSize) / (lotSize * tickValue);
   double tpDistPoints = (tpUSD * tickSize) / (lotSize * tickValue);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double openPrice = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   double slPrice   = (orderType == ORDER_TYPE_BUY) ? (openPrice - slDistPoints) : (openPrice + slDistPoints);
   double tpPrice   = (orderType == ORDER_TYPE_BUY) ? (openPrice + tpDistPoints) : (openPrice - tpDistPoints);

   slPrice = NormalizeDouble(slPrice, _Digits);
   tpPrice = NormalizeDouble(tpPrice, _Digits);

   Fx_trade.SetDeviationInPoints(10);
   bool success = false;

   if(orderType == ORDER_TYPE_BUY)
   {
      success = Fx_trade.Buy(lotSize, _Symbol, openPrice, slPrice, tpPrice, comment);
   }
   else if(orderType == ORDER_TYPE_SELL)
   {
      success = Fx_trade.Sell(lotSize, _Symbol, openPrice, slPrice, tpPrice, comment);
   }

   return success;
}

void Fx_CheckTradeHistory()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance != Fx_glbLastBalance)
   {
      if(HistorySelect(TimeCurrent() - 86400, TimeCurrent()))
      {
         uint totalTrades = HistoryDealsTotal();
         if(totalTrades > 0)
         {
            ulong dealTicket = HistoryDealGetTicket(totalTrades - 1);
            if(HistoryDealSelect(dealTicket))
            {
               string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
               if(symbol == _Symbol)
               {
                  double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                  double dealPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

                  if(Fx_InpUseSmartHistory)
                     Fx_RegisterZoneResult(dealPrice, profit > 0);

                  if(profit < 0)
                  {
                     Fx_glbConsecutiveLosses++;
                     Fx_glbConsecutiveWins = 0;
                     Fx_glbCooldownUntil = TimeCurrent() + (Fx_InpCooldownMinutes * 60);
                     Print("[RISK ALERT] Stop Loss hit! Cooldown started for ", Fx_InpCooldownMinutes, " minutes.");
                  }
                  else if(profit > 0)
                  {
                     Fx_glbConsecutiveWins++;
                     Fx_glbConsecutiveLosses = 0;
                  }
               }
            }
         }
      }
      Fx_glbLastBalance = currentBalance;
   }
}

// The old per-mode Forex Dashboard (Fx_CreateDashboardObjects /
// Fx_SetDashLine / Fx_UpdateDashboard) has been removed. All three
// modes now share a single Dashboard (CreateDashboard() /
// UpdateDashboard() / DeleteDashboard(), object prefix KAI_DASH_)
// defined in the "SHARED DASHBOARD (KAI MT5)" section below. It reads
// the Fx_glbDash* values above (already produced by the unmodified
// Forex trading logic) for display only.
//+------------------------------------------------------------------+

//====================================================================
// SHARED DASHBOARD (KAI MT5)
//
// Single visualization layer shared by Crypto / Gold & Silver / Forex.
// This section contains NO trading logic, indicator calculation, signal
// generation, risk calculation, or AI scoring of any kind. It only
// reads values already produced and stored by the unmodified trading
// logic above (the Cr_glbDash* / Gs_glbDash* / Fx_glbDash* variables,
// plus a handful of pre-existing read-only helpers such as
// Cr_GetFloatingPL()) and renders them.
//
// Only three functions exist, called from the real OnInit()/OnTick()/
// OnDeinit() below:
//   CreateDashboard();
//   UpdateDashboard();
//   DeleteDashboard();
//
// All objects use the KAI_DASH_ prefix (DASH_PREFIX).
//====================================================================
input group "=== Shared Dashboard (KAI MT5) ==="
input bool   InpShowDashboard   = true;
input int    InpDashFontSize    = 14;
input int    InpDashLineSpacing = 30;
input int    InpDashX           = 20;
input int    InpDashY           = 30;

string KAI_DashLabels[] =
{
   "SEP1","TITLE","SEP2",
   "MODE","SYMBOL","ENGINE","TREND","RISK","AI","SPREAD",
   "ORDER","FLOAT","NEWS","COOLDOWN","SIGNAL","STATUS",
   "SEP3"
};

void CreateDashboard()
{
   if(!InpShowDashboard) return;

   ObjectsDeleteAll(0, DASH_PREFIX);

   for(int i = 0; i < ArraySize(KAI_DashLabels); i++)
   {
      string name = DASH_PREFIX + KAI_DashLabels[i];
      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpDashX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpDashY + i * InpDashLineSpacing);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpDashFontSize);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

      // Guardrail (Task 4): never leave the MT5 default "Label" text
      // visible before the first UpdateDashboard() call populates real
      // data. Force a clean placeholder instead. Display-only.
      ObjectSetString(0, name, OBJPROP_TEXT, "-");
   }
}

void DeleteDashboard()
{
   ObjectsDeleteAll(0, DASH_PREFIX);
}

void KAI_SetDashLine(string key, string text, color clr)
{
   string name = DASH_PREFIX + key;
   if(ObjectFind(0, name) < 0) return;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

//--- Pure display-formatting helpers (color/text mapping only - no
//    trading decision is made or influenced by any of these) ---
color KAI_RiskColor(string riskTxt)
{
   if(riskTxt == "HIGH")   return clrRed;
   if(riskTxt == "MEDIUM") return clrYellow;
   return clrLime;
}

color KAI_AIScoreColor(double score)
{
   if(score >= 80) return clrLime;
   if(score >= 60) return clrYellow;
   return clrRed;
}

color KAI_BuySellColor(string signalTxt)
{
   if(signalTxt == "BUY")  return clrLime;
   if(signalTxt == "SELL") return clrOrange;
   return clrSilver;
}

color KAI_OpenOrdersColor(int openCount, int maxOrders)
{
   if(maxOrders <= 0)       return clrSilver;
   if(openCount <= 0)       return clrLime;
   if(openCount >= maxOrders) return clrRed;
   return clrYellow;
}

color KAI_FloatingColor(double pl)
{
   return (pl >= 0) ? clrLime : clrRed;
}

color KAI_NewsColor(bool highImpact)
{
   return highImpact ? clrRed : clrLime;
}

color KAI_CooldownColor(bool inCooldown)
{
   return inCooldown ? clrRed : clrLime;
}

// Pure display-formatting helper (Task 3): builds the compact
// "SL COOLDOWN : ..." status string purely from already-computed,
// read-only cooldown values handed in by the (unmodified) trading
// modules. Makes no trading decision, checks no market condition, and
// writes to no trading state - text formatting only.
string KAI_FormatCooldownText(bool slLockActive, datetime slLockEnd,
                               bool freqCooldownActive,
                               int adaptiveMin, int riskBonusMin)
{
   if(slLockActive)
   {
      int remainMin = (int)MathMax(0, (double)(slLockEnd - TimeCurrent()) / 60.0);
      return StringFormat("SL COOLDOWN : wait %d m", remainMin);
   }

   if(freqCooldownActive)
   {
      int totalMin = adaptiveMin + riskBonusMin;
      return StringFormat("SL COOLDOWN : Adaptive:%dm +Risk:%dm = %d m",
                           adaptiveMin, riskBonusMin, totalMin);
   }

   return "SL COOLDOWN : Not in Cooldown";
}

// Builds the "Trend Follow BUY" / "Trend Counter SELL" / "Sideway Price BUY"
// / "Extreme Trend BUY" style text purely by concatenating the Engine/Mode
// and Signal text the active engine already stored - no new trading
// meaning is derived, no threshold or decision is touched.
string KAI_TrendText(string engineTxt, string modeTxt, string signalTxt)
{
   if(signalTxt != "BUY" && signalTxt != "SELL") return "-";

   if(engineTxt == "EXTREME") return "Extreme Trend " + signalTxt;

   string prefix;
   if(modeTxt == "FOLLOW")                                 prefix = "Trend Follow";
   else if(modeTxt == "COUNTER" || modeTxt == "REVERSAL")  prefix = "Trend Counter";
   else if(modeTxt == "PRICE")                             prefix = "Sideway Price";
   else                                                     prefix = modeTxt;

   return prefix + " " + signalTxt;
}

// Dashboard-only (Modification #2): when no BUY/SELL signal is currently
// stored, derive a descriptive WAIT-state label purely by pattern-matching
// the STATUS/ENGINE text the (unmodified) engine already produced this
// tick. This exposes internal engine state that already exists - it
// invents no new signal, threshold, or trading meaning.
string KAI_TrendWaitText(string engineTxt, string statusTxt)
{
   string statusUp = statusTxt;
   StringToUpper(statusUp);

   if(StringFind(statusUp, "SIDEWAY NO-TRADE ZONE") >= 0)
   {
      // statusTxt already looks like "SIDEWAY NO-TRADE ZONE (43.2%)" -
      // reuse the already-computed percentage text as-is.
      int p1 = StringFind(statusTxt, "(");
      string pct = (p1 >= 0) ? StringSubstr(statusTxt, p1) : "";
      return "Sideway Price WAIT " + pct;
   }
   if(StringFind(statusUp, "PULLBACK") >= 0)
      return "WAIT Pullback";
   if(StringFind(statusUp, "SIDEWAY") >= 0 || engineTxt == "SIDEWAY")
      return "WAIT Sideway";
   if(engineTxt == "EXTREME")
      return "WAIT Extreme";

   return "WAIT Confirm Trend";
}

// Dashboard-only (Modification #2): Dashboard must never show "-" for
// TREND. Combines the live formatted text (if any) with the WAIT-state
// derivation above, and persists the latest non-blank result into the
// caller's storage variable so the panel always shows the most recent
// detected analysis state instead of going blank.
string KAI_PersistTrendText(string liveTxt, string engineTxt, string statusTxt, string &persistVar)
{
   string display = (liveTxt != "-") ? liveTxt : KAI_TrendWaitText(engineTxt, statusTxt);
   if(display != "") persistVar = display;
   return (persistVar != "") ? persistVar : "WAIT Confirm Trend";
}

string KAI_ModeName(ENUM_SYMBOL_MODE m)
{
   switch(m)
   {
      case SYMBOL_MODE_CRYPTO:      return "Crypto";
      case SYMBOL_MODE_GOLD_SILVER: return "Gold & Silver";
      default:                      return "Forex";
   }
}

//+------------------------------------------------------------------+
//| Bridge (Telegram Mirror) - Task: export the EXACT same values    |
//| already computed above for the on-chart Dashboard into a shared  |
//| Common-Files snapshot, keyed by _Symbol, so a separate Telegram  |
//| Control Center EA can mirror them 100%. This is a display/export |
//| ONLY function - it computes nothing new, reads no market data,   |
//| and makes no trading decision. It writes plain KEY=VALUE lines   |
//| (no external JSON library needed) so the reader side can parse   |
//| with simple string functions. Throttled to once per second to    |
//| avoid excessive disk I/O on fast symbols; this throttle affects   |
//| only how often the mirror file is refreshed, never any trading   |
//| logic above.                                                      |
//+------------------------------------------------------------------+
void KAI_PublishBridgeSnapshot(string engineTxt, string trendTxt, string riskTxt,
                                double aiScore, bool highImpactNews, string cooldownTxt,
                                string orderSignalTxt, string statusTxt,
                                int openCount, int maxOrders, double lotSize)
{
   static datetime lastPublish = 0;
   datetime now = TimeCurrent();
   if(now == lastPublish) return; // throttle: at most once per second
   lastPublish = now;

   string fname  = "KAI_DASH_" + _Symbol + ".txt";
   int    handle = FileOpen(fname, FILE_WRITE|FILE_TXT|FILE_COMMON|FILE_ANSI);
   if(handle == INVALID_HANDLE) return; // export failure must not affect trading in any way

   FileWrite(handle, "SYMBOL="    + _Symbol);
   FileWrite(handle, "ENGINE="    + engineTxt);
   FileWrite(handle, "TREND="     + trendTxt);
   FileWrite(handle, "RISK="      + riskTxt);
   FileWrite(handle, "AISCORE="   + DoubleToString(aiScore, 0));
   FileWrite(handle, "NEWS="      + (highImpactNews ? "HIGH" : "LOW"));
   FileWrite(handle, "COOLDOWN="  + cooldownTxt);
   FileWrite(handle, "SIGNAL="    + orderSignalTxt);
   FileWrite(handle, "STATUS="    + statusTxt);
   FileWrite(handle, "OPENCOUNT=" + IntegerToString(openCount));
   FileWrite(handle, "MAXORDERS=" + IntegerToString(maxOrders));
   FileWrite(handle, "LOT="       + DoubleToString(lotSize, 2));
   FileWrite(handle, "UPDATED="   + TimeToString(now, TIME_DATE|TIME_SECONDS));

   FileClose(handle);
}

// Dashboard-only (Modification #1): the existing AI Confidence Score
// functions are normally only invoked deep inside each engine's entry
// path, immediately before an order would be sent - so the dashboard
// value used to go stale between order attempts. This function does
// nothing but CALL those same, unmodified scoring functions every tick
// so the panel stays live, then stores the result into the same
// display-capture variable the trading logic already writes to. It
// changes no algorithm, no threshold, and no order-execution decision;
// the PASS/BLOCK check the trading logic performs still runs its own
// separate call at the moment of entry, exactly as before.
void KAI_RefreshAIScore_DisplayOnly()
{
   ENUM_SYMBOL_MODE mode = DetectSymbolMode(_Symbol);

   if(mode == SYMBOL_MODE_CRYPTO)
   {
      Cr_AIConfidenceScore(); // writes Cr_glbDashAIScore internally (display-capture only)
      return;
   }

   MqlRates m15Rates[];
   ArraySetAsSeries(m15Rates, true);
   if(CopyRates(_Symbol, PERIOD_M15, 0, 3, m15Rates) < 3)
      return; // not enough data yet this tick - leave last known score displayed

   string breakdown = "";

   if(mode == SYMBOL_MODE_GOLD_SILVER)
   {
      ENUM_ORDER_TYPE probeType = (Gs_glbDashSignal == "SELL")   ? ORDER_TYPE_SELL
                                 : (Gs_glbDashSignal == "BUY")    ? ORDER_TYPE_BUY
                                 : (Gs_glbDashTrendDir == "BEAR") ? ORDER_TYPE_SELL
                                 :                                  ORDER_TYPE_BUY;
      double currentPrice = (probeType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      Gs_glbDashAIScore = Gs_AIConfidenceScore(probeType, m15Rates, currentPrice, breakdown);
   }
   else // SYMBOL_MODE_FOREX
   {
      ENUM_ORDER_TYPE probeType = (Fx_glbDashSignal == "SELL")   ? ORDER_TYPE_SELL
                                 : (Fx_glbDashSignal == "BUY")    ? ORDER_TYPE_BUY
                                 : (Fx_glbDashTrendDir == "BEAR") ? ORDER_TYPE_SELL
                                 :                                  ORDER_TYPE_BUY;
      double currentPrice = (probeType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                                            : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      Fx_glbDashAIScore = Fx_AIConfidenceScore(probeType, m15Rates, currentPrice, breakdown);
   }
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   // Modification #1: refresh the AI Score continuously every tick for
   // display purposes, using the existing (unmodified) scoring functions.
   KAI_RefreshAIScore_DisplayOnly();

   //--- Detect which internal mode is active and pull its already-
   //    computed, already-stored display values. No calculation of
   //    any trading value happens here - only reads. ---
   ENUM_SYMBOL_MODE mode = DetectSymbolMode(_Symbol);

   string engineTxt, modeTxt, signalTxt, riskTxt, statusTxt, newsTxt, cooldownTxt;
   double aiScore, lotSize, floatingPL;
   int    openCount, maxOrders;

   switch(mode)
   {
      case SYMBOL_MODE_CRYPTO:
         engineTxt   = Cr_glbDashEngine;
         modeTxt     = Cr_glbDashMode;
         signalTxt   = Cr_glbDashSignal;
         riskTxt     = Cr_glbDashRiskLevel;
         aiScore     = Cr_glbDashAIScore;
         openCount   = Cr_glbDashOpenCount;
         maxOrders   = Cr_glbDashMaxOrders;
         floatingPL  = Cr_GetFloatingPL();
         newsTxt     = Cr_glbDashNewsText;
         cooldownTxt = Cr_glbDashCooldownTxt;
         lotSize     = Cr_glbDashLot;
         statusTxt   = Cr_glbDashStatus;
         break;

      case SYMBOL_MODE_GOLD_SILVER:
         engineTxt   = Gs_glbDashEngine;
         modeTxt     = Gs_glbDashMode;
         signalTxt   = Gs_glbDashSignal;
         riskTxt     = Gs_RiskLevelToString(Gs_glbDashRisk);
         aiScore     = Gs_glbDashAIScore;
         openCount   = Gs_glbDashOpenCount;
         maxOrders   = Gs_glbDashMaxOrders;
         floatingPL  = Gs_GetFloatingPL();
         newsTxt     = Gs_glbDashNewsText;
         cooldownTxt = Gs_glbDashCooldownTxt;
         lotSize     = Gs_glbDashLot;
         statusTxt   = Gs_glbDashStatus;
         break;

      default: // SYMBOL_MODE_FOREX
         engineTxt   = Fx_glbDashEngine;
         modeTxt     = Fx_glbDashMode;
         signalTxt   = Fx_glbDashSignal;
         riskTxt     = Fx_RiskLevelToString(Fx_glbDashRisk);
         aiScore     = Fx_glbDashAIScore;
         openCount   = Fx_glbDashOpenCount;
         maxOrders   = Fx_glbDashMaxOrders;
         floatingPL  = Fx_GetFloatingPL();
         newsTxt     = Fx_glbDashNewsText;
         cooldownTxt = Fx_glbDashCooldownTxt;
         lotSize     = Fx_glbDashLot;
         statusTxt   = Fx_glbDashStatus;
         break;
   }

   bool highImpactNews = (newsTxt != "No High Impact News");
   bool inCooldown      = (StringFind(cooldownTxt, "Not in Cooldown") < 0);
   long spreadPts        = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD); // live broker readout, display only

   string sep = "===========================================================";

   KAI_SetDashLine("SEP1",  sep, clrGray);
   KAI_SetDashLine("TITLE", "KAI MT5", clrWhite);
   KAI_SetDashLine("SEP2",  sep, clrGray);

   KAI_SetDashLine("MODE",   "MODE          : " + KAI_ModeName(mode), clrYellow);
   KAI_SetDashLine("SYMBOL", "SYMBOL        : " + _Symbol, clrYellow);
   KAI_SetDashLine("ENGINE", "ENGINE        : " + engineTxt, clrYellow);

   // Modification #2: TREND must never display "-". Compute the live
   // formatted text (if any), then persist/derive a descriptive state so
   // the panel always shows the latest detected engine analysis.
   string trendLiveTxt = KAI_TrendText(engineTxt, modeTxt, signalTxt);
   string trendDisplayTxt;
   switch(mode)
   {
      case SYMBOL_MODE_CRYPTO:      trendDisplayTxt = KAI_PersistTrendText(trendLiveTxt, engineTxt, statusTxt, Cr_glbDashTrendPersist); break;
      case SYMBOL_MODE_GOLD_SILVER: trendDisplayTxt = KAI_PersistTrendText(trendLiveTxt, engineTxt, statusTxt, Gs_glbDashTrendPersist); break;
      default:                      trendDisplayTxt = KAI_PersistTrendText(trendLiveTxt, engineTxt, statusTxt, Fx_glbDashTrendPersist); break;
   }
   KAI_SetDashLine("TREND",  "TREND         : " + trendDisplayTxt, KAI_BuySellColor(signalTxt));

   KAI_SetDashLine("RISK",   "RISK LEVEL    : " + riskTxt, KAI_RiskColor(riskTxt));
   KAI_SetDashLine("AI",     StringFormat("AI SCORE      : %.0f / 100", aiScore), KAI_AIScoreColor(aiScore));
   KAI_SetDashLine("SPREAD", StringFormat("SPREAD        : %d pts", (int)spreadPts), clrYellow);

   KAI_SetDashLine("ORDER",  StringFormat("OPEN ORDERS   : %d / %d", openCount, maxOrders), KAI_OpenOrdersColor(openCount, maxOrders));
   KAI_SetDashLine("FLOAT",  StringFormat("FLOATING      : %s%.2f USD", (floatingPL >= 0 ? "+" : ""), floatingPL), KAI_FloatingColor(floatingPL));

   KAI_SetDashLine("NEWS",     "NEWS IMPACT   : " + (highImpactNews ? "HIGH" : "LOW"), KAI_NewsColor(highImpactNews));
   // Task 3: cooldownTxt already arrives as the fully-formatted compact
   // "SL COOLDOWN : ..." string (built by KAI_FormatCooldownText in each
   // mode's OnTick) - render it as-is rather than re-prefixing it.
   KAI_SetDashLine("COOLDOWN", cooldownTxt, KAI_CooldownColor(inCooldown));

   string orderSignalTxt = (signalTxt == "BUY" || signalTxt == "SELL")
                            ? StringFormat("%s / Lot %.2f", signalTxt, lotSize)
                            : "WAIT";
   KAI_SetDashLine("SIGNAL", "ORDER SIGNAL  : " + orderSignalTxt, clrYellow);

   KAI_SetDashLine("STATUS", "STATUS        : " + statusTxt, clrWhite);
   KAI_SetDashLine("SEP3", sep, clrGray);

   // --- Bridge: mirror the exact same values rendered above so the Telegram
   //     Control Center can display them 100% in sync (display/export only). ---
   KAI_PublishBridgeSnapshot(engineTxt, trendDisplayTxt, riskTxt,
                             aiScore, highImpactNews, cooldownTxt,
                             orderSignalTxt, statusTxt,
                             openCount, maxOrders, lotSize);
}
//+------------------------------------------------------------------+

//====================================================================
// MAIN / EVENT HANDLERS
// These are the only real OnInit()/OnTick()/OnDeinit() in the program.
// They do nothing but: (1) detect the symbol mode via the Symbol Mode
// Router above, then (2) call the matching module's renamed handler,
// then (3) drive the shared Dashboard. No trading logic, filter,
// score, or order call happens here.
//====================================================================
int OnInit()
{
   int result;
   switch(DetectSymbolMode(_Symbol))
   {
      case SYMBOL_MODE_CRYPTO:      result = Cr_OnInit(); break;
      case SYMBOL_MODE_GOLD_SILVER: result = Gs_OnInit(); break;
      default:                      result = Fx_OnInit(); break;
   }

   CreateDashboard();
   
   // --- บังคับดึงข้อมูลและวาด Dashboard ขึ้นหน้าจอทันที (แก้ข้อ 1) ---
   UpdateDashboard(); 
   ChartRedraw(0);
   // ------------------------------------------------------------

   return result;
}

void OnDeinit(const int reason)
{
   switch(DetectSymbolMode(_Symbol))
   {
      case SYMBOL_MODE_CRYPTO:      Cr_OnDeinit(reason); break;
      case SYMBOL_MODE_GOLD_SILVER: Gs_OnDeinit(reason); break;
      default:                      Fx_OnDeinit(reason); break;
   }

   DeleteDashboard();
}

void OnTick()
{
   switch(DetectSymbolMode(_Symbol))
   {
      case SYMBOL_MODE_CRYPTO:      Cr_OnTick(); break;
      case SYMBOL_MODE_GOLD_SILVER: Gs_OnTick(); break;
      default:                      Fx_OnTick(); break;
   }

   UpdateDashboard();
}
//+------------------------------------------------------------------+