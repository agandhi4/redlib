// static/comment-collapse.js — replaces the existing file.
// Existing behavior (click a comment body to collapse it) is unchanged;
// two additions: collapse-all / expand-all, and collapse-children.

document.addEventListener("click", (e) => {
  // ── Collapse all / expand all (buttons in post.html's #comment_tools)
  const tool = e.target.closest("[data-comments]");
  if (tool) {
    e.preventDefault();
    const open = tool.dataset.comments === "expand";
    document.querySelectorAll("details.comment_right").forEach((d) => (d.open = open));
    return;
  }

  // ── Collapse just this comment's replies, keeping the comment itself open
  const kids = e.target.closest(".collapse_children");
  if (kids) {
    e.preventDefault();
    kids
      .closest("details.comment_right")
      .querySelectorAll(".replies details.comment_right")
      .forEach((d) => (d.open = false));
    return;
  }

  // ── Click a comment body to collapse it (unchanged)
  const body = e.target.closest(".comment_body");
  if (!body) return;
  if (e.target.closest("a, button, input, textarea, video, details")) return;
  const selection = window.getSelection();
  if (selection && selection.toString().length > 0) return;
  const details = body.closest("details");
  if (details) details.open = !details.open;
});
