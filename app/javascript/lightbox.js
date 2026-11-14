/* The lightbox of the room page (lightbox_controller.js of Rails Campfire): a click on an image preview opens the image
   in the modal dialog of the page, with the link that downloads it. Without this file, the preview is a plain link to
   the image. A click with a modifier key keeps the browser's own meaning (a new tab). */
export function startLightbox() {
  "use strict";

  var dialog = document.querySelector("dialog.lightbox");
  if (!dialog || !dialog.showModal) {
    return;
  }

  var image = dialog.querySelector("img");
  var download = dialog.querySelector("a[download]");

  document.addEventListener("click", function (event) {
    var link = event.target.closest && event.target.closest("a[data-lightbox]");
    if (!link || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) {
      return;
    }

    event.preventDefault();
    var preview = link.querySelector("img");
    image.src = link.href;
    image.alt = preview ? preview.alt : "";
    download.href = link.dataset.download;
    dialog.showModal();
  });

  // A click on the backdrop is a click on the dialog itself.
  dialog.addEventListener("click", function (event) {
    if (event.target === dialog) {
      dialog.close();
    }
  });

  dialog.addEventListener("close", function () {
    image.removeAttribute("src");
    download.removeAttribute("href");
  });
}
