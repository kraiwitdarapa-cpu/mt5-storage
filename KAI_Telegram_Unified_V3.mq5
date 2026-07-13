//+------------------------------------------------------------------+
//|            KAI_Telegram_Unified_V3.mq5 (Hub + Observer Merged)  |
//|                                                              Kai  |
//|  Version: 3.11 + 2.04 Merged                                     |
//|  - ControlCenter Hub (main menu, symbol report)                  |
//|  - Observer (trade notify, drawdown, profit panel)               |
//|  - Heartbeat ทุก 3 ชั่วโมง ตลอด 7 วัน (ไม่เช็คตลาด/วันหยุด)        |
//|  - Pin เฉพาะ Main Banner และ Close All Profit Panel               |
//|  - ปุ่ม Observer เปลี่ยนเป็น "Update Now" + callback update_now_panel |
//+------------------------------------------------------------------+
#property copyright "Kai"
#property version   "3.20"
#property strict

#include <Trade\Trade.mqh>

//====================================================================
//  INPUT PARAMETERS
//====================================================================
input string   InpBotToken    = "8802663315:AAH-6P78LJ30XbAAwdxc4pR0lEUcEsUKMb8"; // Telegram Bot Token
input string   InpChatID      = "8592796190";                                       // Telegram Chat ID
input string   InpPrefix      = "[VPS-1]";                                          // Prefix Name
input double   InpDDThreshold = 70.0;                                               // % Drawdown Alert (70%)

//====================================================================
//  GLOBAL VARIABLES — ControlCenter Hub
//====================================================================
long      last_update_offset  = 0;       // offset สำหรับ getUpdates ของ Hub
int       gl_main_menu_msg_id = 0;       // message_id ของเมนูหลัก Hub
bool      gl_is_photo_menu    = false;   // ติดตามว่าเมนูปัจจุบันเป็น photo หรือ text

const string MAIN_MENU_BANNER_URL =
   "https://raw.githubusercontent.com/kraiwitdarapa-cpu/mt5-storage/"
   "8b4eeb70ae575429f91f384d17cdb1518a96f6fa/messageImage_1783866234174.jpg";

//====================================================================
//  GLOBAL VARIABLES — Observer (Heartbeat + Drawdown)
//====================================================================
datetime last_running_time = 0;   // ใช้ใน OnTick() เพื่อ Heartbeat ทุก 3 ชั่วโมง
datetime last_dd_time      = 0;   // ใช้ใน OnTick() เพื่อ throttle แจ้ง DD

//====================================================================
//  GLOBAL VARIABLES — Profit Control Panel (Observer)
//====================================================================
long     g_panel_msg_id   = 0;   // message_id ของ Profit Panel (persistent)
long     g_last_update_id = 0;   // offset ของ getUpdates สำหรับ Observer Panel

//====================================================================
//  OnInit
//====================================================================
int OnInit()
{
   // ── Observer: ส่งข้อความเริ่มทำงาน ──────────────────────────────
   SendTelegram(InpPrefix + " 🤖 *บอทแจ้งเตือนเริ่มทำงาน (START)* \nระบบสแตนด์บายเฝ้าดูพอร์ต (บัญชีร่วม) เรียบร้อยครับ");
   last_running_time = TimeCurrent();
   last_dd_time      = TimeCurrent() - 3600;

   // ── ตั้ง Timer ทุก 1 วินาที (รวม Hub + Panel polling) ─────────
   EventSetTimer(1);

   // ── Hub: สร้างเมนูหลักครั้งแรก ────────────────────────────────
   SendControlCenterMain();

   // ── Observer: โหลด/สร้าง Profit Panel ─────────────────────────
   InitProfitControlPanel();

   return(INIT_SUCCEEDED);
}

//====================================================================
//  OnDeinit
//====================================================================
void OnDeinit(const int reason)
{
   SendTelegram(InpPrefix + " 🛑 *บอทแจ้งเตือนหยุดทำงาน (STOP)*");
   EventKillTimer();
}

//====================================================================
//  OnTick  — Heartbeat ทุก 3 ชั่วโมง (ไม่เช็คตลาด / วันหยุด)
//====================================================================
void OnTick()
{
   datetime now = TimeCurrent();

   // Heartbeat ทุก 3 ชั่วโมง (10800 วินาที) ตลอด 7 วัน ไม่มีข้อยกเว้น
   if(now - last_running_time >= 10800)
   {
      SendTelegram(InpPrefix + " ⏳ *MT5 ยืนยันทำงานปกติ*");
      last_running_time = now;
   }

   // Drawdown Alert
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance > 0)
   {
      double current_dd = ((balance - equity) / balance) * 100.0;
      if(current_dd >= InpDDThreshold)
      {
         if(now - last_dd_time >= 3600)
         {
            string dd_msg = InpPrefix + " ⚠️ *🚨 DRAWDOWN ALERT!!* \n" +
                            "พอร์ตโดนลากหนัก Equity ต่ำกว่ากำหนด!\n" +
                            "Floating Loss: -" + DoubleToString(current_dd, 2) + "%\n" +
                            "🔵 Equity คงเหลือ: $" + DoubleToString(equity, 2);
            SendTelegram(dd_msg);   // ห้าม Pin — แจ้งเตือนทั่วไป
            last_dd_time = now;
         }
      }
   }
}

//====================================================================
//  OnTradeTransaction — แจ้งเตือนเปิด/ปิดไม้ (Observer)
//====================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong deal_ticket = trans.deal;
      if(HistoryDealSelect(deal_ticket))
      {
         long   entry  = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
         string symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
         double volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
         double price  = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
         long   type   = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);

         int trade_number = GetDailyTradeNumber();
         if(entry == DEAL_ENTRY_IN)
         {
            string type_str = (type == DEAL_TYPE_BUY) ? "🟢 BUY" : "🔴 SELL";
            string msg = InpPrefix + " " + type_str + " (ไม้ที่ " + IntegerToString(trade_number) + ") " +
                         "สัญลักษณ์: " + symbol + " | Vol: " + DoubleToString(volume, 2) + " @ " + DoubleToString(price, _Digits);
            SendTelegram(msg);   // ห้าม Pin — แจ้งเตือน BUY/SELL ทั่วไป
         }
         else if(entry == DEAL_ENTRY_OUT)
         {
            long   reason = HistoryDealGetInteger(deal_ticket, DEAL_REASON);
            double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT)
                          + HistoryDealGetDouble(deal_ticket, DEAL_SWAP)
                          + HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

            string reason_str = "Close";
            string emoji      = "⚪";
            if(reason == DEAL_REASON_SL)       { reason_str = "Stop Loss";   emoji = "🔴"; }
            else if(reason == DEAL_REASON_TP)  { reason_str = "Take Profit"; emoji = "🔵"; }

            string profit_prefix   = (profit >= 0) ? "+$" : "-$";
            double display_profit  = (profit >= 0) ? profit : -profit;
            string msg = InpPrefix + " " + emoji + " CLOSED " + symbol + " #" + IntegerToString(deal_ticket) +
                         " (" + reason_str + ") Profit: " + profit_prefix + DoubleToString(display_profit, 2);
            SendTelegram(msg);   // ห้าม Pin — รายงานปิดไม้ทั่วไป

            SendDailyReport();   // ห้าม Pin — Summary Report ทั่วไป
         }
      }
   }
}

//====================================================================
//  OnTimer — รวม Hub polling + Observer panel polling
//====================================================================
void OnTimer()
{
   // 1) Hub: ดักรับปุ่มกด Control Center
   FetchTelegramUpdates();

   // 2) Observer: ดักรับปุ่ม Profit Panel
   PollTelegramUpdates();
}

//====================================================================
//
//       ⭐  CONTROL CENTER HUB MODULE  ⭐
//
//====================================================================

void FetchTelegramUpdates()
{
   string url = "https://api.telegram.org/bot" + InpBotToken +
                "/getUpdates?offset=" + IntegerToString(last_update_offset) + "&limit=1&timeout=0";
   char   post_data[], result[];
   string result_headers;

   int res = WebRequest("GET", url, NULL, 10, post_data, result, result_headers);
   if(res == 200 && ArraySize(result) > 0)
   {
      string response_str = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

      // อัปเดต offset
      int find_id = StringFind(response_str, "\"update_id\":");
      if(find_id >= 0)
      {
         int start_pos = find_id + 12;
         int end_pos   = StringFind(response_str, ",", start_pos);
         if(end_pos > start_pos)
         {
            string id_str      = StringSubstr(response_str, start_pos, end_pos - start_pos);
            long   current_id  = StringToInteger(id_str);
            if(current_id >= last_update_offset)
               last_update_offset = current_id + 1;
         }
      }

      // ดักจับ callback_data จาก Hub
      string cb_data = KAI_ExtractCallbackData(response_str);

      if(cb_data == "main_menu")                       { SendControlCenterMain(); }
      else if(cb_data == "menu_crypto")                { SendSymbolMenu("Crypto"); }
      else if(cb_data == "menu_gold")                  { SendSymbolMenu("Gold & Silver"); }
      else if(cb_data == "menu_forex")                 { SendSymbolMenu("Forex"); }
      else if(StringFind(cb_data, "sym_") == 0)
      {
         string tapped_symbol = StringSubstr(cb_data, 4);
         SendSummaryReport(tapped_symbol, KAI_SymbolModeText(tapped_symbol));
      }
      else if(StringFind(cb_data, "refresh_") == 0)
      {
         // ป้องกัน Hub ไม่ให้ดักจับ refresh_panel / update_now_panel ของ Observer
         string refresh_tail = StringSubstr(cb_data, 8);
         if(refresh_tail != "panel" && refresh_tail != "now_panel")
         {
            SendSummaryReport(refresh_tail, KAI_SymbolModeText(refresh_tail));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| UI: หน้าแรก Main Menu + Banner                                    |
//+------------------------------------------------------------------+
void SendControlCenterMain()
{
   string inline_keyboard = "{\"inline_keyboard\":[[" +
      "{\"text\":\"🪙 Crypto\",\"callback_data\":\"menu_crypto\"}," +
      "{\"text\":\"🥇 Gold & Silver\",\"callback_data\":\"menu_gold\"}]," +
      "[{\"text\":\"💱 Forex Mode\",\"callback_data\":\"menu_forex\"}]]}";

   if(gl_main_menu_msg_id > 0)
   {
      if(gl_is_photo_menu)
      {
         EditTelegramReplyMarkupCustom(gl_main_menu_msg_id, inline_keyboard);
      }
      else
      {
         DeleteTelegramMessage(gl_main_menu_msg_id);
         gl_main_menu_msg_id = SendTelegramPhotoCustom(MAIN_MENU_BANNER_URL, inline_keyboard);
         // ✅ Pin เฉพาะ Main Controller Banner
         PinTelegramMessage(gl_main_menu_msg_id);
         gl_is_photo_menu = true;
      }
   }
   else
   {
      gl_main_menu_msg_id = SendTelegramPhotoCustom(MAIN_MENU_BANNER_URL, inline_keyboard);
      // ✅ Pin เฉพาะ Main Controller Banner
      PinTelegramMessage(gl_main_menu_msg_id);
      gl_is_photo_menu = true;
   }
}

//+------------------------------------------------------------------+
//| UI: เมนูเลือกคู่เงิน                                              |
//+------------------------------------------------------------------+
void SendSymbolMenu(string mode)
{
   string text = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

   if(mode == "Forex")             text += "💱 *FOREX MODE*\n\nเลือก Symbol ที่ต้องการตรวจสอบ\n(Active Symbols เรียงตามตัวอักษร A-Z)\n";
   else if(mode == "Gold & Silver") text += "🥇 *GOLD & SILVER MODE*\n\nเลือก Symbol ที่ต้องการตรวจสอบ\n(Active Symbols เรียงตามตัวอักษร A-Z)\n";
   else if(mode == "Crypto")        text += "🪙 *CRYPTO MODE*\n\nเลือก Symbol ที่ต้องการตรวจสอบ\n(Active Symbols เรียงตามตัวอักษร A-Z)\n";

   string found_symbols[];
   int    found_count = KAI_ScanActiveSymbolsByMode(mode, found_symbols);
   string inline_keyboard;

   if(found_count == 0)
   {
      text += "⚠️ ไม่พบกราฟที่กำลังรัน EA อยู่ในโหมดนี้ในขณะนี้\n";
      inline_keyboard = "{\"inline_keyboard\":[[{\"text\":\"🔙 Main Menu\",\"callback_data\":\"main_menu\"}]]}";
   }
   else
   {
      inline_keyboard = "{\"inline_keyboard\":[";
      int per_row = 3;
      for(int i = 0; i < found_count; i++)
      {
         if(i % per_row == 0) inline_keyboard += (i == 0) ? "[" : "],[";
         else                 inline_keyboard += ",";
         string emo = KAI_SymbolEmoji(found_symbols[i]);
         inline_keyboard += "{\"text\":\"" + emo + " " + found_symbols[i] + "\",\"callback_data\":\"sym_" + found_symbols[i] + "\"}";
      }
      inline_keyboard += "],[{\"text\":\"🔙 Main Menu\",\"callback_data\":\"main_menu\"}]]}";
   }

   text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";

   if(gl_main_menu_msg_id > 0)
   {
      if(gl_is_photo_menu)
      {
         DeleteTelegramMessage(gl_main_menu_msg_id);
         gl_main_menu_msg_id = SendTelegramCustom(text, inline_keyboard);
         // ❌ ห้าม Pin — หน้า Symbol Menu ทั่วไป
         gl_is_photo_menu = false;
      }
      else
      {
         EditTelegramCustom(gl_main_menu_msg_id, text, inline_keyboard);
      }
   }
   else
   {
      gl_main_menu_msg_id = SendTelegramCustom(text, inline_keyboard);
      // ❌ ห้าม Pin
      gl_is_photo_menu = false;
   }
}

//+------------------------------------------------------------------+
//| Hub helpers: Scan / Symbol Utils                                  |
//+------------------------------------------------------------------+
int KAI_ScanActiveSymbols(string &out_symbols[])
{
   ArrayResize(out_symbols, 0);
   long chart_id = ChartFirst();
   while(chart_id >= 0)
   {
      string expert_name = ChartGetString(chart_id, CHART_EXPERT_NAME);
      if(StringFind(expert_name, "Hybrid_Ultimate_EA") >= 0)
      {
         string sym = ChartSymbol(chart_id);
         if(StringLen(sym) > 0)
         {
            bool already_have = false;
            int  n = ArraySize(out_symbols);
            for(int i = 0; i < n; i++) if(out_symbols[i] == sym) { already_have = true; break; }
            if(!already_have) { ArrayResize(out_symbols, n + 1); out_symbols[n] = sym; }
         }
      }
      chart_id = ChartNext(chart_id);
   }
   return ArraySize(out_symbols);
}

string KAI_SymbolModeText(string symbol)
{
   string s = symbol;
   StringToUpper(s);
   if(StringFind(s, "BTC") >= 0 || StringFind(s, "ETH") >= 0) return "Crypto";
   if(StringFind(s, "XAU") >= 0 || StringFind(s, "XAG") >= 0) return "Gold & Silver";
   return "Forex";
}

int KAI_ScanActiveSymbolsByMode(string mode, string &out_symbols[])
{
   string all_symbols[];
   int    all_count = KAI_ScanActiveSymbols(all_symbols);
   ArrayResize(out_symbols, 0);
   for(int i = 0; i < all_count; i++)
   {
      if(KAI_SymbolModeText(all_symbols[i]) == mode)
      {
         int n = ArraySize(out_symbols);
         ArrayResize(out_symbols, n + 1);
         out_symbols[n] = all_symbols[i];
      }
   }
   return ArraySize(out_symbols);
}

string KAI_SymbolEmoji(string symbol)
{
   string s = symbol;
   StringToUpper(s);
   if(StringFind(s, "BTC") >= 0) return "🪙";
   if(StringFind(s, "ETH") >= 0) return "💎";
   if(StringFind(s, "XAU") >= 0) return "🥇";
   if(StringFind(s, "XAG") >= 0) return "🥈";
   string base = StringSubstr(s, 0, 3);
   if(base == "EUR") return "🇪🇺";
   if(base == "USD") return "🇺🇸";
   if(base == "GBP") return "🇬🇧";
   if(base == "JPY") return "🇯🇵";
   if(base == "AUD") return "🇦🇺";
   if(base == "NZD") return "🇳🇿";
   if(base == "CAD") return "🇨🇦";
   if(base == "CHF") return "🇨🇭";
   return "💱";
}

string KAI_ExtractCallbackData(string response_str)
{
   int pos = StringFind(response_str, "\"data\":\"");
   if(pos < 0) return "";
   int start = pos + 8;
   int end   = StringFind(response_str, "\"", start);
   if(end <= start) return "";
   return StringSubstr(response_str, start, end - start);
}

bool KAI_ReadBridge(string symbol,
                    string &engine, string &trend, string &risk,
                    int &aiScore, string &news, string &cooldown,
                    string &signal, string &status, int &maxOrders,
                    double &lot, datetime &updated)
{
   string fname  = "KAI_DASH_" + symbol + ".txt";
   int    handle = FileOpen(fname, FILE_READ|FILE_TXT|FILE_COMMON|FILE_ANSI);
   if(handle == INVALID_HANDLE) return false;
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      int eq = StringFind(line, "=");
      if(eq < 0) continue;
      string key = StringSubstr(line, 0, eq);
      string val = StringSubstr(line, eq + 1);
      if(key == "ENGINE")         engine    = val;
      else if(key == "TREND")     trend     = val;
      else if(key == "RISK")      risk      = val;
      else if(key == "AISCORE")   aiScore   = (int)StringToInteger(val);
      else if(key == "NEWS")      news      = val;
      else if(key == "COOLDOWN")  cooldown  = val;
      else if(key == "SIGNAL")    signal    = val;
      else if(key == "STATUS")    status    = val;
      else if(key == "MAXORDERS") maxOrders = (int)StringToInteger(val);
      else if(key == "LOT")       lot       = StringToDouble(val);
      else if(key == "UPDATED")   updated   = StringToTime(val);
   }
   FileClose(handle);
   return true;
}

int KAI_GetOpenCount(string symbol)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol) count++;
   }
   return count;
}

double KAI_GetFloatingPL(string symbol)
{
   double sum = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == symbol)
         sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return sum;
}

void SendSummaryReport(string symbol, string mode)
{
   string   engine = "-", trend = "-", risk = "-", news = "-", cooldown = "-", signal = "WAIT", status = "-";
   int      aiScore = 0, maxOrders = 0;
   double   lot = 0.0;
   datetime updated = 0;

   bool bridgeOk = KAI_ReadBridge(symbol, engine, trend, risk, aiScore, news, cooldown, signal, status, maxOrders, lot, updated);
   string aiScoreTxt;

   if(!bridgeOk)
   {
      engine = trend = risk = news = cooldown = "⚠️ NO LIVE DATA";
      signal = "WAIT";
      status = "⚠️ HYBRID_ULTIMATE_EA NOT ATTACHED TO THIS SYMBOL CHART";
      aiScoreTxt = "N/A";
   }
   else
   {
      aiScoreTxt = IntegerToString(aiScore) + " / 100";
      if(updated > 0 && (TimeCurrent() - updated) > 120)
         status += "  (⚠️ STALE " + IntegerToString((int)(TimeCurrent() - updated)) + "s)";
   }

   SymbolSelect(symbol, true);
   long   spreadPts  = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   int    openCount  = KAI_GetOpenCount(symbol);
   double floatingPL = KAI_GetFloatingPL(symbol);
   string floatEmoji = (floatingPL >= 0) ? "🟢" : "🔴";

   string text = "🤖 *KAI MT5 AI-ENGINE SUMMARY* 🤖\n" +
                 "--------------------------------------------------\n" +
                 "📌 *[ CONFIG ]*\n" +
                 "🔹 Mode: " + mode + "\n" +
                 "🔹 Symbol: " + symbol + "\n" +
                 "🔸 Engine Type: " + engine + "\n" +
                 "🔸 Trend: " + trend + "\n\n" +
                 "📊 *[ MARKET & AI ]*\n" +
                 "🔹 Risk Level: " + risk + "\n" +
                 "🔹 News Impact: " + news + "\n" +
                 "🔸 SL Cooldown: " + cooldown + "\n" +
                 "🔸 AI Score: " + aiScoreTxt + "\n" +
                 "--------------------------------------------------\n" +
                 "💰 *[ PERFORMANCE ]*\n" +
                 "🔸 Spread: " + IntegerToString((int)spreadPts) + " pts\n" +
                 "🔹 Open Orders: " + IntegerToString(openCount) + " / " + (bridgeOk ? IntegerToString(maxOrders) : "N/A") + "\n" +
                 floatEmoji + " Active Floating: " + DoubleToString(floatingPL, 2) + " USD\n\n" +
                 "⚙️ *[ SYSTEM STATUS ]*\n" +
                 "🔹 Order Signal: ⚠️ " + (bridgeOk ? signal : "WAIT") + "\n" +
                 "🔹 Current Status: " + status + "\n" +
                 "--------------------------------------------------\n" +
                 "⏱ *Update:* " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);

   string back_callback = "menu_forex";
   if(mode == "Crypto")          back_callback = "menu_crypto";
   else if(mode == "Gold & Silver") back_callback = "menu_gold";

   string inline_keyboard = "{\"inline_keyboard\":[[" +
      "{\"text\":\"🔄 Refresh Status\",\"callback_data\":\"refresh_" + symbol + "\"}]," +
      "[{\"text\":\"🔙 " + mode + " Menu\",\"callback_data\":\"" + back_callback + "\"},{\"text\":\"🏠 Main Menu\",\"callback_data\":\"main_menu\"}]]}";

   // ❌ ห้าม Pin — Summary Report ทั่วไป
   if(gl_main_menu_msg_id > 0)
   {
      if(gl_is_photo_menu)
      {
         DeleteTelegramMessage(gl_main_menu_msg_id);
         gl_main_menu_msg_id = SendTelegramCustom(text, inline_keyboard);
         gl_is_photo_menu = false;
      }
      else
      {
         EditTelegramCustom(gl_main_menu_msg_id, text, inline_keyboard);
      }
   }
   else
   {
      gl_main_menu_msg_id = SendTelegramCustom(text, inline_keyboard);
      gl_is_photo_menu = false;
   }
}

//====================================================================
//
//       ⭐  OBSERVER MODULE  ⭐
//
//====================================================================

//+------------------------------------------------------------------+
//| GetDailyTradeNumber                                               |
//+------------------------------------------------------------------+
int GetDailyTradeNumber()
{
   datetime day_start = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   HistorySelect(day_start, TimeCurrent());
   int total_deals = HistoryDealsTotal();
   int count = 0;
   for(int i = 0; i < total_deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) count++;
      }
   }
   return (count == 0) ? 1 : count;
}

//+------------------------------------------------------------------+
//| SendDailyReport — ห้าม Pin                                        |
//+------------------------------------------------------------------+
void SendDailyReport()
{
   datetime day_start = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   HistorySelect(day_start, TimeCurrent());
   int total_deals = HistoryDealsTotal();
   double daily_profit = 0;
   int win_count = 0, loss_count = 0;

   for(int i = 0; i < total_deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT)
         {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                       HistoryDealGetDouble(ticket, DEAL_SWAP)   +
                       HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            daily_profit += p;
            if(p > 0) win_count++;
            else if(p < 0) loss_count++;
         }
      }
   }

   string profit_emoji = "⚪";
   if(daily_profit > 0) profit_emoji = "🟢";
   else if(daily_profit < 0) profit_emoji = "🔴";

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   string report_msg = InpPrefix + " 📊 *SUMMARY REPORT*\n" +
                       profit_emoji + " *Daily Profit/Loss:* $" + DoubleToString(daily_profit, 2) + "\n" +
                       "🟢 *Win Rate:* ชนะ " + IntegerToString(win_count) + " ไม้ | 🔴 แพ้ " + IntegerToString(loss_count) + " ไม้\n" +
                       "🔵 *Account Balance:* $" + DoubleToString(balance, 2) + "\n" +
                       "🔵 *Equity:* $" + DoubleToString(equity, 2);
   SendTelegram(report_msg);   // ❌ ห้าม Pin
}

//====================================================================
//  Profit Control Panel (Observer) — Pin เฉพาะ Panel นี้
//====================================================================

void InitProfitControlPanel()
{
   string keyPanelId = InpPrefix + "_TG_PANEL_MSGID";
   string keyOffset  = InpPrefix + "_TG_UPDATE_OFFSET";

   if(GlobalVariableCheck(keyPanelId))
      g_panel_msg_id = (long)GlobalVariableGet(keyPanelId);

   if(GlobalVariableCheck(keyOffset))
      g_last_update_id = (long)GlobalVariableGet(keyOffset);

   if(g_panel_msg_id > 0)
      RefreshControlPanel();
   else
      SendControlPanel();
}

string FormatUSD(double v)
{
   if(v > 0.0) return "+" + DoubleToString(v, 2) + " USD";
   return DoubleToString(v, 2) + " USD";
}

double CalculateOpenProfit()
{
   double total = 0.0;
   int total_positions = PositionsTotal();
   for(int i = total_positions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > 0.0) total += profit;
   }
   return total;
}

void CloseAllProfitablePositions(int &closedCount, int &skippedCount, double &realizedProfit)
{
   closedCount    = 0;
   skippedCount   = 0;
   realizedProfit = 0.0;

   CTrade panel_trade;
   panel_trade.SetDeviationInPoints(30);

   int total_positions = PositionsTotal();
   for(int i = total_positions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit <= 0.0) continue;

      string symbol    = PositionGetString(POSITION_SYMBOL);
      long   tradeMode = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
      MqlTick tick;
      bool hasTick = SymbolInfoTick(symbol, tick);
      if(tradeMode == SYMBOL_TRADE_MODE_DISABLED || !hasTick) { skippedCount++; continue; }

      double before = profit;
      bool ok = panel_trade.PositionClose(ticket);
      if(!ok) { skippedCount++; continue; }

      closedCount++;
      realizedProfit += before;
   }
}

// ─── ✅ เปลี่ยนปุ่ม Refresh เป็น "Update Now" + callback "update_now_panel" ───
string BuildPanelKeyboard(double profitOpen)
{
   string btnText = "💰 Close Profit (" + FormatUSD(profitOpen) + ")";
   string keyboard = "{\"inline_keyboard\":[[{\"text\":\"" + EscapeJsonStringNew(btnText) +
                      "\",\"callback_data\":\"closeprofit\"}]," +
                      "[{\"text\":\"🔄 Update Now\",\"callback_data\":\"update_now_panel\"}]]}";
   return keyboard;
}

string EscapeJsonStringNew(string s)
{
   string r = s;
   StringReplace(r, "\\", "\\\\");
   StringReplace(r, "\"", "\\\"");
   StringReplace(r, "\n", "\\n");
   StringReplace(r, "\r", "");
   return r;
}

bool JsonGetStringNew(const string json, const string key, string &out_value)
{
   string pattern = "\"" + key + "\":\"";
   int p = StringFind(json, pattern);
   if(p < 0) return false;
   p += StringLen(pattern);
   int e = StringFind(json, "\"", p);
   if(e < 0) return false;
   out_value = StringSubstr(json, p, e - p);
   return true;
}

bool JsonGetNumberNew(const string json, const string key, long &out_value)
{
   string pattern = "\"" + key + "\":";
   int p = StringFind(json, pattern);
   if(p < 0) return false;
   p += StringLen(pattern);
   int e = p;
   int len = StringLen(json);
   while(e < len)
   {
      ushort ch = StringGetCharacter(json, e);
      if((ch >= '0' && ch <= '9') || ch == '-') e++;
      else break;
   }
   if(e == p) return false;
   out_value = StringToInteger(StringSubstr(json, p, e - p));
   return true;
}

bool JsonGetChatIdNew(const string json, long &chatId)
{
   string pattern = "\"chat\":{\"id\":";
   int p = StringFind(json, pattern);
   if(p < 0) return false;
   p += StringLen(pattern);
   int e = p;
   int len = StringLen(json);
   while(e < len)
   {
      ushort ch = StringGetCharacter(json, e);
      if((ch >= '0' && ch <= '9') || ch == '-') e++;
      else break;
   }
   if(e == p) return false;
   chatId = StringToInteger(StringSubstr(json, p, e - p));
   return true;
}

int SplitJsonObjectsNew(const string arrayJson, string &objects[])
{
   int depth = 0, start = -1, count = 0;
   ArrayResize(objects, 0);
   int len = StringLen(arrayJson);
   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(arrayJson, i);
      if(ch == '{') { if(depth == 0) start = i; depth++; }
      else if(ch == '}')
      {
         depth--;
         if(depth == 0 && start >= 0)
         {
            string obj = StringSubstr(arrayJson, start, i - start + 1);
            count++;
            ArrayResize(objects, count);
            objects[count - 1] = obj;
            start = -1;
         }
      }
   }
   return count;
}

bool TelegramApiPost(string method, string jsonBody, string &responseOut)
{
   string url = "https://api.telegram.org/bot" + InpBotToken + "/" + method;
   string headers = "Content-Type: application/json\r\n";
   char post_data[], result[];
   string result_headers;
   StringToCharArray(jsonBody, post_data, 0, StringLen(jsonBody), CP_UTF8);
   int res = WebRequest("POST", url, headers, 10, post_data, result, result_headers);
   if(res != 200) { responseOut = ""; return false; }
   responseOut = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return true;
}

void AnswerCallbackQueryNew(string callbackQueryId)
{
   if(callbackQueryId == "") return;
   string body = "{\"callback_query_id\":\"" + callbackQueryId + "\"}";
   string resp;
   TelegramApiPost("answerCallbackQuery", body, resp);
}

void DeleteMessageNew(long msgId)
{
   if(msgId <= 0) return;
   string body = "{\"chat_id\":\"" + InpChatID + "\",\"message_id\":" + IntegerToString(msgId) + "}";
   string resp;
   TelegramApiPost("deleteMessage", body, resp);
}

void PinMessageNew(long msgId)
{
   if(msgId <= 0) return;
   string body = "{\"chat_id\":\"" + InpChatID + "\",\"message_id\":" + IntegerToString(msgId) + "}";
   string resp;
   TelegramApiPost("pinChatMessage", body, resp);
}

//+------------------------------------------------------------------+
//| SendControlPanel — ✅ Pin Profit Panel                             |
//+------------------------------------------------------------------+
void SendControlPanel()
{
   double profit  = CalculateOpenProfit();
   string keyboard = BuildPanelKeyboard(profit);
   string imgUrl = "https://raw.githubusercontent.com/kraiwitdarapa-cpu/mt5-storage/main/images.jpg";
   string body = "{\"chat_id\":\"" + InpChatID + "\",\"photo\":\"" + imgUrl + "\",\"reply_markup\":" + keyboard + "}";
   string resp;
   if(TelegramApiPost("sendPhoto", body, resp))
   {
      long msgId = 0;
      if(JsonGetNumberNew(resp, "message_id", msgId))
      {
         g_panel_msg_id = msgId;
         GlobalVariableSet(InpPrefix + "_TG_PANEL_MSGID", (double)g_panel_msg_id);
         // ✅ Pin เฉพาะ Close All Profit Panel
         PinMessageNew(g_panel_msg_id);
      }
   }
}

void RefreshControlPanel()
{
   if(g_panel_msg_id <= 0)
   {
      string keyPanelId = InpPrefix + "_TG_PANEL_MSGID";
      if(GlobalVariableCheck(keyPanelId))
         g_panel_msg_id = (long)GlobalVariableGet(keyPanelId);
   }
   if(g_panel_msg_id <= 0) { SendControlPanel(); return; }

   double profit   = CalculateOpenProfit();
   string keyboard = BuildPanelKeyboard(profit);
   string bodyMarkup = "{\"chat_id\":\"" + InpChatID + "\",\"message_id\":" + IntegerToString(g_panel_msg_id) +
                        ",\"reply_markup\":" + keyboard + "}";
   string respMarkup;
   bool okMarkup = TelegramApiPost("editMessageReplyMarkup", bodyMarkup, respMarkup);
   if(!okMarkup)
   {
      g_panel_msg_id = 0;
      SendControlPanel();
   }
}

void HandleCloseProfitCommandNew()
{
   int closed = 0, skipped = 0;
   double realized = 0.0;
   CloseAllProfitablePositions(closed, skipped, realized);

   string msg = "✅ Close Profit Completed\n\n" +
                "Closed : " + IntegerToString(closed) + " Positions\n" +
                "Skipped (Market Closed) : " + IntegerToString(skipped) + " Positions\n" +
                "Realized Profit : " + FormatUSD(realized);
   SendTelegram(msg);   // ❌ ห้าม Pin — รายงานผลการ Close

   if(g_panel_msg_id > 0) DeleteMessageNew(g_panel_msg_id);
   g_panel_msg_id = 0;
   SendControlPanel();   // ✅ Panel ใหม่จะถูก Pin โดย SendControlPanel()
}

// ─── ✅ ดักจับ callback "update_now_panel" แทน "refresh_panel" ───
void ProcessTelegramUpdateNew(string obj)
{
   long updId;
   if(JsonGetNumberNew(obj, "update_id", updId))
   {
      if(updId > g_last_update_id)
      {
         g_last_update_id = updId;
         GlobalVariableSet(InpPrefix + "_TG_UPDATE_OFFSET", (double)g_last_update_id);
      }
   }

   long chatId = 0;
   if(JsonGetChatIdNew(obj, chatId))
      if(IntegerToString(chatId) != InpChatID) return;

   if(StringFind(obj, "\"callback_query\":") >= 0)
   {
      string data = "";
      JsonGetStringNew(obj, "data", data);

      string cbid = "";
      JsonGetStringNew(obj, "id", cbid);
      AnswerCallbackQueryNew(cbid);

      if(data == "closeprofit")
         HandleCloseProfitCommandNew();
      else if(data == "update_now_panel")   // ✅ เปลี่ยนจาก "refresh_panel"
         RefreshControlPanel();
   }
   else if(StringFind(obj, "\"message\":") >= 0)
   {
      string text = "";
      JsonGetStringNew(obj, "text", text);

      if(text == "/closeprofit")
         HandleCloseProfitCommandNew();
      else if(text == "/panel")
         RefreshControlPanel();
   }
}

void PollTelegramUpdates()
{
   string offsetParam = (g_last_update_id > 0)
                         ? ("?offset=" + IntegerToString(g_last_update_id + 1) + "&timeout=0")
                         : "?timeout=0";
   string url = "https://api.telegram.org/bot" + InpBotToken + "/getUpdates" + offsetParam;

   char post_data[], result[];
   string result_headers;
   int res = WebRequest("GET", url, "", 5, post_data, result, result_headers);
   if(res != 200) return;

   string json = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string pattern = "\"result\":[";
   int arrPos = StringFind(json, pattern);
   if(arrPos < 0) return;

   string arrPart = StringSubstr(json, arrPos + StringLen(pattern));
   string items[];
   int n = SplitJsonObjectsNew(arrPart, items);
   for(int i = 0; i < n; i++)
      ProcessTelegramUpdateNew(items[i]);
}

//====================================================================
//
//       ⭐  SHARED TELEGRAM UTILITIES  ⭐
//
//====================================================================

void SendTelegram(string text)
{
   string url     = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + InpChatID + "&text=" + UrlEncodeMQL5(text) + "&parse_mode=Markdown";
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

int SendTelegramCustom(string text, string reply_markup)
{
   string url     = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + InpChatID + "&text=" + UrlEncodeMQL5(text) + "&parse_mode=Markdown&reply_markup=" + UrlEncodeMQL5(reply_markup);
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   int res = WebRequest("POST", url, headers, 10, post_data, result, result_headers);
   if(res == 200 && ArraySize(result) > 0)
   {
      string response_str = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      int pos = StringFind(response_str, "\"message_id\":");
      if(pos >= 0)
      {
         int start = pos + 13;
         int end   = StringFind(response_str, ",", start);
         if(end < 0) end = StringFind(response_str, "}", start);
         if(end > start) return (int)StringToInteger(StringSubstr(response_str, start, end - start));
      }
   }
   return 0;
}

void EditTelegramCustom(int message_id, string text, string reply_markup)
{
   if(message_id <= 0) return;
   string url     = "https://api.telegram.org/bot" + InpBotToken + "/editMessageText";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id) + "&text=" + UrlEncodeMQL5(text) + "&parse_mode=Markdown&reply_markup=" + UrlEncodeMQL5(reply_markup);
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

int SendTelegramPhotoCustom(string photo_file_id, string reply_markup)
{
   string url     = "https://api.telegram.org/bot" + InpBotToken + "/sendPhoto";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + InpChatID + "&photo=" + UrlEncodeMQL5(photo_file_id) + "&reply_markup=" + UrlEncodeMQL5(reply_markup);
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   int res = WebRequest("POST", url, headers, 10, post_data, result, result_headers);
   if(res == 200 && ArraySize(result) > 0)
   {
      string response_str = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      int pos = StringFind(response_str, "\"message_id\":");
      if(pos >= 0)
      {
         int start = pos + 13;
         int end   = StringFind(response_str, ",", start);
         if(end < 0) end = StringFind(response_str, "}", start);
         if(end > start) return (int)StringToInteger(StringSubstr(response_str, start, end - start));
      }
   }
   return 0;
}

void EditTelegramReplyMarkupCustom(int message_id, string reply_markup)
{
   if(message_id <= 0) return;
   string url     = "https://api.telegram.org/bot" + InpBotToken + "/editMessageReplyMarkup";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id) + "&reply_markup=" + UrlEncodeMQL5(reply_markup);
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

void PinTelegramMessage(int message_id)
{
   if(message_id <= 0) return;
   string url     = "https://api.telegram.org/bot" + InpBotToken + "/pinChatMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id) + "&disable_notification=true";
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

void DeleteTelegramMessage(int message_id)
{
   if(message_id <= 0) return;
   string url     = "https://api.telegram.org/bot" + InpBotToken + "/deleteMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post    = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id);
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

string UrlEncodeMQL5(string text)
{
   char array[];
   int len = StringToCharArray(text, array, 0, WHOLE_ARRAY, CP_UTF8);
   string encoded = "";
   for(int i = 0; i < len - 1; i++)
   {
      int c = array[i] & 0xFF;
      if((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
         c == '-' || c == '_' || c == '.' || c == '!' || c == '~' || c == '*' || c == '\'' || c == '(' || c == ')')
         encoded += CharToString((char)c);
      else if(c == ' ')
         encoded += "+";
      else
         encoded += "%" + StringFormat("%02X", c);
   }
   return encoded;
}
//+------------------------------------------------------------------+
