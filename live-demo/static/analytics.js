// Day 04：GA4 電子商務事件埋設（view_item_list → view_item → begin_checkout → purchase）
(function () {
  "use strict";

  var config = JSON.parse(document.getElementById("demo-config").textContent);
  var enabled = Boolean(config.gaId) && typeof window.gtag === "function";

  function track(name, params) {
    if (!enabled) {
      console.info("[live-demo] GA4 未設定，略過事件：", name, params);
      return;
    }
    window.gtag("event", name, params);
  }

  function readItem(card) {
    var item = JSON.parse(card.getAttribute("data-item"));
    item.item_brand = config.brand;
    return item;
  }

  // 1. 商品列表曝光
  var list = document.querySelector(".product-grid");
  if (list) {
    var cards = Array.prototype.slice.call(list.querySelectorAll(".product-card"));
    track("view_item_list", {
      item_list_id: list.getAttribute("data-list-id"),
      item_list_name: list.getAttribute("data-list-name"),
      items: cards.map(readItem)
    });

    cards.forEach(function (card) {
      var item = readItem(card);

      // 2. 展開商品細節視為一次商品檢視（每張卡片只送一次）
      var details = card.querySelector("details");
      var viewed = false;
      details.addEventListener("toggle", function () {
        if (details.open && !viewed) {
          viewed = true;
          track("view_item", { currency: config.currency, value: item.price, items: [item] });
        }
      });

      // 3. 開始結帳：先送 begin_checkout，並把 GA client_id 帶到伺服器，再跳轉
      var form = card.querySelector(".checkout-form");
      form.addEventListener("submit", function (event) {
        var qty = parseInt(form.querySelector("select[name=qty]").value, 10) || 1;
        var checkoutItem = Object.assign({}, item, { quantity: qty });
        delete checkoutItem.index;
        if (!enabled) {
          track("begin_checkout", { currency: config.currency, value: item.price * qty, items: [checkoutItem] });
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
            value: item.price * qty,
            items: [checkoutItem],
            event_callback: go
          });
        });
        window.setTimeout(go, 1200); // 廣告攔截器擋掉 GA 時也不能卡住結帳
      });
    });
  }

  // 4. 購買完成：只有伺服器驗證成功的感謝頁才會輸出 purchase-data
  var purchase = document.getElementById("purchase-data");
  if (purchase) {
    var data = JSON.parse(purchase.textContent);
    if (data.transaction_id) {
      track("purchase", data);
    }
  }
})();
