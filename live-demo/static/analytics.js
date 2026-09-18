// Day 04：GA4 電子商務事件埋設
// 列表曝光 view_item_list → 點商品 select_item → 商品頁 view_item →
// 活動頁 view_promotion / select_promotion → 結帳 begin_checkout → 感謝頁 purchase
(function () {
  "use strict";

  var config = JSON.parse(document.getElementById("demo-config").textContent);
  var enabled = Boolean(config.gaId) && typeof window.gtag === "function";
  var SOURCE_KEY = "demo_traffic_source";

  function track(name, params) {
    if (!enabled) {
      console.info("[live-demo] GA4 未設定，略過事件：", name, params);
      return;
    }
    window.gtag("event", name, params);
  }

  // ── 進站來源：把 utm 參數記在工作階段中，結帳時一起帶給伺服器 ──────────────
  function rememberTrafficSource() {
    var q = new URLSearchParams(window.location.search);
    var source = q.get("utm_source");
    if (!source) { return; }
    var value = [source, q.get("utm_medium") || "none", q.get("utm_campaign") || "none"]
      .join("|")
      .replace(/[^A-Za-z0-9_.|-]/g, "")
      .slice(0, 50);
    try { window.sessionStorage.setItem(SOURCE_KEY, value); } catch (e) { /* 無痕模式忽略 */ }
  }

  function trafficSource() {
    try { return window.sessionStorage.getItem(SOURCE_KEY) || ""; } catch (e) { return ""; }
  }

  rememberTrafficSource();

  function readItem(el) {
    var item = JSON.parse(el.getAttribute("data-item"));
    item.item_brand = config.brand;
    return item;
  }

  // ── 1. 商品列表曝光與點擊 ──────────────────────────────────────────────
  Array.prototype.forEach.call(document.querySelectorAll(".product-grid"), function (list) {
    var cards = Array.prototype.slice.call(list.querySelectorAll(".product-card"));
    if (!cards.length) { return; }
    track("view_item_list", {
      item_list_id: list.getAttribute("data-list-id"),
      item_list_name: list.getAttribute("data-list-name"),
      items: cards.map(readItem)
    });

    cards.forEach(function (card) {
      var item = readItem(card);
      Array.prototype.forEach.call(card.querySelectorAll("a"), function (link) {
        link.addEventListener("click", function () {
          track("select_item", {
            item_list_id: item.item_list_id,
            item_list_name: item.item_list_name,
            items: [item]
          });
        });
      });
    });
  });

  // ── 2. 商品詳情頁：view_item 與圖片切換 ────────────────────────────────
  var detail = document.querySelector(".product-detail");
  if (detail) {
    var product = readItem(detail);
    track("view_item", { currency: config.currency, value: product.price, items: [product] });

    var main = document.getElementById("gallery-main");
    Array.prototype.forEach.call(document.querySelectorAll(".thumb"), function (thumb) {
      thumb.addEventListener("click", function () {
        main.src = thumb.getAttribute("data-src");
        Array.prototype.forEach.call(document.querySelectorAll(".thumb"), function (t) {
          t.classList.remove("is-active");
        });
        thumb.classList.add("is-active");
      });
    });
  }

  // ── 3. 活動著陸頁：view_promotion / select_promotion ───────────────────
  var lp = document.querySelector(".lp-hero");
  if (lp) {
    var promotion = JSON.parse(lp.getAttribute("data-promotion"));
    track("view_promotion", promotion);
    Array.prototype.forEach.call(document.querySelectorAll(".lp-hero a, .campaign-card"), function (el) {
      el.addEventListener("click", function () { track("select_promotion", promotion); });
    });
  }

  // ── 4. 開始結帳：送 begin_checkout，並把 client_id 與來源帶給伺服器 ────
  var form = detail ? detail.querySelector(".checkout-form") : null;
  if (form) {
    var buyItem = readItem(detail);
    form.addEventListener("submit", function (event) {
      var qty = parseInt(form.querySelector("select[name=qty]").value, 10) || 1;
      var checkoutItem = Object.assign({}, buyItem, { quantity: qty });
      var srcField = form.querySelector("input[name=src]");
      if (srcField) { srcField.value = trafficSource(); }
      if (!enabled) {
        track("begin_checkout", { currency: config.currency, value: buyItem.price * qty, items: [checkoutItem] });
        return;
      }
      event.preventDefault();
      var submitted = false;
      function go() {
        if (!submitted) { submitted = true; form.submit(); }
      }
      window.gtag("get", config.gaId, "client_id", function (clientId) {
        form.querySelector("input[name=cid]").value = clientId || "";
        window.gtag("event", "begin_checkout", {
          currency: config.currency,
          value: buyItem.price * qty,
          items: [checkoutItem],
          event_callback: go
        });
      });
      window.setTimeout(go, 1200); // 廣告攔截器擋掉 GA 時也不能卡住結帳
    });
  }

  // ── 5. 購買完成：只有伺服器驗證成功的感謝頁才會輸出 purchase-data ──────
  var purchase = document.getElementById("purchase-data");
  if (purchase) {
    var data = JSON.parse(purchase.textContent);
    if (data.transaction_id) {
      track("purchase", data);
    }
  }
})();
