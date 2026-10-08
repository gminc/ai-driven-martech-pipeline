// Day 26：對話頁
// 回答一律用 textContent 放進頁面，當成純文字顯示，不解讀 Markdown 也不解讀 HTML
// 這是 Day 23 說的「真正的控制在顯示的那一層」：回答裡就算混進圖片或連結的語法，這裡也只會照字面印出來
(function () {
  "use strict";
  var log = document.getElementById("log");
  var form = document.getElementById("form");
  var input = document.getElementById("q");
  var send = document.getElementById("send");
  var reset = document.getElementById("reset");
  var status = document.getElementById("status");
  var sessionId = "";   // 只放在這個分頁的記憶體裡，重新整理就是一場新的對話

  function add(who, text) {
    var li = document.createElement("li");
    li.className = who;
    li.textContent = text;
    log.appendChild(li);
    li.scrollIntoView({ block: "end" });
  }

  function busy(on) {
    send.disabled = on;
    input.disabled = on;
    if (on) { status.textContent = "查詢中，第一句可能要等十幾秒"; }
  }

  reset.addEventListener("click", function () {
    sessionId = "";
    log.textContent = "";
    status.textContent = "已經開了一場新的對話";
    input.focus();
  });

  input.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing && e.keyCode !== 229) {   // 229：輸入法還在選字
      e.preventDefault();
      form.requestSubmit();
    }
  });

  form.addEventListener("submit", function (e) {
    e.preventDefault();
    var question = input.value.trim();
    if (!question) { return; }
    add("me", question);
    input.value = "";
    busy(true);
    fetch("/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Martech-Chat": "1" },
      body: JSON.stringify({ question: question, session_id: sessionId })
    }).then(function (r) {
      // 回來的不一定是 JSON（權限被拿掉、逾時的時候是一頁 HTML），那種情況只顯示狀態碼
      return r.json().then(function (d) { return { code: r.status, data: d }; },
                           function () { return { code: r.status, data: { error: "助理沒有回答（HTTP " + r.status + "），可能是沒有權限或等太久，請找資料管理者" } }; });
    }).then(function (r) {
      var d = r.data || {};
      if (d.restarted) { add("note", "原本那場對話接不回來（超過 30 分鐘沒動，或紀錄暫時讀不到），這一句從新的對話開始"); }
      if (d.restored) { add("note", "服務剛換了一台，這場對話是從紀錄接回來的，前面查到的明細需要的話會重查"); }
      if (d.session_id) { sessionId = d.session_id; }
      add("bot", d.answer || d.error || "沒有拿到回答（" + r.code + "）");
      status.textContent = typeof d.turns_left === "number" ? "這場對話還可以問 " + d.turns_left + " 句" : "";
    }).catch(function () {
      add("note", "連不上助理，請確認 proxy 還開著再試一次");
      status.textContent = "";
    }).then(function () {
      busy(false);
      input.focus();
    });
  });
})();
