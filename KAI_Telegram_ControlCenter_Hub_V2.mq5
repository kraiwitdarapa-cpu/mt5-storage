//+------------------------------------------------------------------+
//|                               KAI_Telegram_ControlCenter_Hub.mq5 |
//|                                                              Kai |
//+------------------------------------------------------------------+
#property copyright "Kai"
#property version   "3.11"
#property strict

//--- Inputs
input string   InpBotToken    = "8802663315:AAH-6P78LJ30XbAAwdxc4pR0lEUcEsUKMb8"; // Telegram Bot Token
input string   InpChatID      = "8592796190";                                     // Telegram Chat ID
input string   InpPrefix      = "[VPS-1]";                                        // Prefix Name

//--- Global Variables สำหรับระบบ Control Center (ระบบจำข้อความเพื่อใช้สำหรับ Edit ป้องกันการยิงซ้ำ)
long      last_update_offset = 0;
int       gl_main_menu_msg_id = 0; // จำ ID ข้อความหลักเพื่อใช้ในการแก้ไข (Edit) แทนการส่งใหม่
bool      gl_is_photo_menu = false; // ตัวแปรเช็คสถานะว่าเมนูปัจจุบันเป็นรูปภาพหรือไม่ (ป้องกัน Error ลบ/แก้ข้อความ)

//--- [UI ONLY] Banner Image (Main Menu Header) - แสดงผ่าน sendPhoto() แทน Text Header เดิม
const string MAIN_MENU_BANNER_URL = "https://raw.githubusercontent.com/kraiwitdarapa-cpu/mt5-storage/8b4eeb70ae575429f91f384d17cdb1518a96f6fa/messageImage_1783866234174.jpg";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // เปิด Timer สำหรับเช็คปุ่มกด Telegram Control Center (ทำงานทุก 1 วินาที)
   EventSetTimer(1);
   
   // เรียกสร้างหน้าต่างเมนูหลักครั้งแรก
   SendControlCenterMain();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function (นำโค้ดแจ้งเตือน Drawdown ออกเพื่อไม่ให้ซ้ำ)      |
//+------------------------------------------------------------------+
void OnTick()
{
   // เคลียร์โค้ดแจ้งเตือนซ้ำซ้อนออก ปล่อยให้ไฟล์ Observer ทำหน้าที่แทน
}

//+------------------------------------------------------------------+
//| OnTradeTransaction function (นำโค้ดแจ้งเตือนการเปิด/ปิดไม้ออก)          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // เคลียร์โค้ดแจ้งเตือนซ้ำซ้อนออก ปล่อยให้ไฟล์ Observer ทำหน้าที่แทน
}

//====================================================================
//                 ⭐ TELEGRAM CONTROL CENTER MODULE ⭐
//====================================================================

void OnTimer()
{
   FetchTelegramUpdates();
}

void FetchTelegramUpdates()
{
   string url = "https://api.telegram.org/bot" + InpBotToken + "/getUpdates?offset=" + IntegerToString(last_update_offset) + "&limit=1&timeout=0";
   char post_data[], result[];
   string result_headers;
   
   int res = WebRequest("GET", url, NULL, 10, post_data, result, result_headers);
   
   if(res == 200 && ArraySize(result) > 0)
   {
      string response_str = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
      int find_id = StringFind(response_str, "\"update_id\":");
      if(find_id >= 0)
      {
         int start_pos = find_id + 12;
         int end_pos = StringFind(response_str, ",", start_pos);
         if(end_pos > start_pos)
         {
            string id_str = StringSubstr(response_str, start_pos, end_pos - start_pos);
            long current_id = StringToInteger(id_str);
            if(current_id >= last_update_offset) last_update_offset = current_id + 1;
         }
      }
      
      // การดักจับ Callback Data เพื่อเปลี่ยนหน้าจอ UI (สลับเมนูแบบแก้ไขข้อความเดิม)
      string cb_data = KAI_ExtractCallbackData(response_str);
      
      if(cb_data == "main_menu")                       { SendControlCenterMain(); }
      else if(cb_data == "menu_crypto")                { SendSymbolMenu("Crypto"); }
      else if(cb_data == "menu_gold")                  { SendSymbolMenu("Gold & Silver"); }
      else if(cb_data == "menu_forex")                 { SendSymbolMenu("Forex"); }
      // การดักจับปุ่มสัญลักษณ์คู่เงิน (Dynamic) - callback_data คือ "sym_<SYMBOL จริง>"
      else if(StringFind(cb_data, "sym_") == 0)
      {
         string tapped_symbol = StringSubstr(cb_data, 4);
         SendSummaryReport(tapped_symbol, KAI_SymbolModeText(tapped_symbol));
      }
      // ปุ่มรีเฟรชข้อมูลหน้า Report (Dynamic) - callback_data คือ "refresh_<SYMBOL จริง>"
      else if(StringFind(cb_data, "refresh_") == 0)
      {
         string refresh_symbol = StringSubstr(cb_data, 8);
         SendSummaryReport(refresh_symbol, KAI_SymbolModeText(refresh_symbol));
      }
   }
}

//+------------------------------------------------------------------+
//| UI: หน้าแรก (Main Menu + แถบการ์ดสไตล์เรียบหรู)
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
         // ถ้าเป็นรูปภาพอยู่แล้ว แก้ไขเฉพาะปุ่ม
         EditTelegramReplyMarkupCustom(gl_main_menu_msg_id, inline_keyboard);
      }
      else
      {
         // ถ้าเปลี่ยนมาจากหน้า Text ให้ลบ Text ทิ้งก่อน แล้วค่อยส่งรูปภาพใหม่
         DeleteTelegramMessage(gl_main_menu_msg_id);
         gl_main_menu_msg_id = SendTelegramPhotoCustom(MAIN_MENU_BANNER_URL, inline_keyboard);
         PinTelegramMessage(gl_main_menu_msg_id);
         gl_is_photo_menu = true;
      }
   }
   else
   {
      gl_main_menu_msg_id = SendTelegramPhotoCustom(MAIN_MENU_BANNER_URL, inline_keyboard);
      PinTelegramMessage(gl_main_menu_msg_id);
      gl_is_photo_menu = true;
   }
}

//+------------------------------------------------------------------+
//| UI: เมนูเลือกคู่เงิน (Symbol Menu)
//+------------------------------------------------------------------+
void SendSymbolMenu(string mode)
{
   string text = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
   
   if(mode == "Forex")            text += "💱 *FOREX MODE*\n\nเลือก Symbol ที่ต้องการตรวจสอบ\n(Active Symbols เรียงตามตัวอักษร A-Z)\n";
   else if(mode == "Gold & Silver") text += "🥇 *GOLD & SILVER MODE*\n\nเลือก Symbol ที่ต้องการตรวจสอบ\n(Active Symbols เรียงตามตัวอักษร A-Z)\n";
   else if(mode == "Crypto")       text += "🪙 *CRYPTO MODE*\n\nเลือก Symbol ที่ต้องการตรวจสอบ\n(Active Symbols เรียงตามตัวอักษร A-Z)\n";
   
   string found_symbols[];
   int found_count = KAI_ScanActiveSymbolsByMode(mode, found_symbols);
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
         // ถ้าเปิดมาจากหน้าแรกที่เป็นรูปภาพ ให้ลบรูปภาพทิ้งก่อน แล้วส่งหน้า Text
         DeleteTelegramMessage(gl_main_menu_msg_id);
         gl_main_menu_msg_id = SendTelegramCustom(text, inline_keyboard);
         gl_is_photo_menu = false;
      }
      else
      {
         // ถ้าเปลี่ยนมาจากหน้า Text ด้วยกันเอง ให้ Edit ข้อความ (ไม่กระตุก)
         EditTelegramCustom(gl_main_menu_msg_id, text, inline_keyboard);
      }
   }
   else
   {
      gl_main_menu_msg_id = SendTelegramCustom(text, inline_keyboard);
      gl_is_photo_menu = false;
   }
}

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
            for(int i = 0; i < n; i++)
            {
               if(out_symbols[i] == sym) { already_have = true; break; }
            }
            if(!already_have)
            {
               ArrayResize(out_symbols, n + 1);
               out_symbols[n] = sym;
            }
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
   string baseCurrency = StringSubstr(s, 0, 3);
   if(baseCurrency == "EUR") return "🇪🇺";
   if(baseCurrency == "USD") return "🇺🇸";
   if(baseCurrency == "GBP") return "🇬🇧";
   if(baseCurrency == "JPY") return "🇯🇵";
   if(baseCurrency == "AUD") return "🇦🇺";
   if(baseCurrency == "NZD") return "🇳🇿";
   if(baseCurrency == "CAD") return "🇨🇦";
   if(baseCurrency == "CHF") return "🇨🇭";
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
   string orderSignalTxt = bridgeOk ? signal : "WAIT";
   string maxOrdersTxt    = bridgeOk ? IntegerToString(maxOrders) : "N/A";

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
                 "🔹 Open Orders: " + IntegerToString(openCount) + " / " + maxOrdersTxt + "\n" +
                 floatEmoji + " Active Floating: " + DoubleToString(floatingPL, 2) + " USD\n\n" +
                 "⚙️ *[ SYSTEM STATUS ]*\n" +
                 "🔹 Order Signal: ⚠️ " + orderSignalTxt + "\n" +
                 "🔹 Current Status: " + status + "\n" +
                 "--------------------------------------------------\n" +
                 "⏱ *Update:* " + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);

   string back_callback = "menu_forex";
   if(mode == "Crypto") back_callback = "menu_crypto";
   else if(mode == "Gold & Silver") back_callback = "menu_gold";
   
   string inline_keyboard = "{\"inline_keyboard\":[[" +
      "{\"text\":\"🔄 Refresh Status\",\"callback_data\":\"refresh_" + symbol + "\"}]," +
      "[{\"text\":\"🔙 " + mode + " Menu\",\"callback_data\":\"" + back_callback + "\"},{\"text\":\"🏠 Main Menu\",\"callback_data\":\"main_menu\"}]]}";
      
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

void SendTelegram(string text)
{
   string url = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post = "chat_id=" + InpChatID + "&text=" + UrlEncodeMQL5(text) + "&parse_mode=Markdown";
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

int SendTelegramCustom(string text, string reply_markup)
{
   string url = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post = "chat_id=" + InpChatID + "&text=" + UrlEncodeMQL5(text) + "&parse_mode=Markdown&reply_markup=" + UrlEncodeMQL5(reply_markup);
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
         int end = StringFind(response_str, ",", start);
         if(end < 0) end = StringFind(response_str, "}", start);
         if(end > start) return (int)StringToInteger(StringSubstr(response_str, start, end - start));
      }
   }
   return 0;
}

void EditTelegramCustom(int message_id, string text, string reply_markup)
{
   if(message_id <= 0) return;
   string url = "https://api.telegram.org/bot" + InpBotToken + "/editMessageText";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id) + "&text=" + UrlEncodeMQL5(text) + "&parse_mode=Markdown&reply_markup=" + UrlEncodeMQL5(reply_markup);
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

int SendTelegramPhotoCustom(string photo_file_id, string reply_markup)
{
   string url = "https://api.telegram.org/bot" + InpBotToken + "/sendPhoto";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post = "chat_id=" + InpChatID + "&photo=" + UrlEncodeMQL5(photo_file_id) + "&reply_markup=" + UrlEncodeMQL5(reply_markup);
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
         int end = StringFind(response_str, ",", start);
         if(end < 0) end = StringFind(response_str, "}", start);
         if(end > start) return (int)StringToInteger(StringSubstr(response_str, start, end - start));
      }
   }
   return 0;
}

void EditTelegramReplyMarkupCustom(int message_id, string reply_markup)
{
   if(message_id <= 0) return;
   string url = "https://api.telegram.org/bot" + InpBotToken + "/editMessageReplyMarkup";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id) + "&reply_markup=" + UrlEncodeMQL5(reply_markup);
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

void PinTelegramMessage(int message_id)
{
   if(message_id <= 0) return;
   string url = "https://api.telegram.org/bot" + InpBotToken + "/pinChatMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id) + "&disable_notification=true";
   char post_data[], result[];
   string result_headers;
   StringToCharArray(post, post_data, 0, StringLen(post));
   WebRequest("POST", url, headers, 10, post_data, result, result_headers);
}

void DeleteTelegramMessage(int message_id)
{
   if(message_id <= 0) return;
   string url = "https://api.telegram.org/bot" + InpBotToken + "/deleteMessage";
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   string post = "chat_id=" + InpChatID + "&message_id=" + IntegerToString(message_id);
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
      {
         encoded += CharToString((char)c);
      }
      else if(c == ' ') encoded += "+";
      else encoded += "%" + StringFormat("%02X", c);
   }
   return encoded;
}