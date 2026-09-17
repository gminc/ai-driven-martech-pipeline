// 讓使用者看一眼金額後，自動把表單 POST 到綠界測試環境
window.setTimeout(function () {
  var form = document.getElementById("ecpay-form");
  if (form) { form.submit(); }
}, 800);
