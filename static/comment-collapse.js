document.addEventListener("click", (e) => {
  // Only act on clicks inside comment bodies
  const body = e.target.closest(".comment_body");
  if (!body) return;

  // Don't collapse when clicking links, buttons, or interactive elements
  if (e.target.closest("a, button, input, textarea, video, details")) return;

  // Don't collapse if user is selecting text
  const selection = window.getSelection();
  if (selection && selection.toString().length > 0) return;

  // Toggle the parent <details> element
  const details = body.closest("details");
  if (details) {
    details.open = !details.open;
  }
});
