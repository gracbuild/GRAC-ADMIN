/* ============================================================================
   GRAC Pager — the single pagination control used by every grid in the
   product.  Pair it with `.grac-grid` / `.grac-grid-body` from grac-grid.css.

   Mount once, then call `update()` after each render:

     const pager = GracPager.mount(document.querySelector("#gridPager"), {
       pageSize: 10,
       onChange: ({ page, pageSize }) => load()
     });

     pager.update({ page: state.page, pageSize: state.pageSize, total: 132 });

   Helpers:
     GracPager.slice(array, page, pageSize)   -> rows for the current page
     GracPager.lastPage(total, pageSize)      -> highest valid page number
   ==========================================================================*/
(function (global) {
  "use strict";

  var DEFAULT_SIZES = [10, 25, 50, 100];
  var DEFAULT_SIZE = 10;

  function clampPage(page, total, pageSize) {
    var last = lastPage(total, pageSize);
    return Math.min(Math.max(1, Number(page) || 1), last);
  }

  function lastPage(total, pageSize) {
    var size = Math.max(1, Number(pageSize) || DEFAULT_SIZE);
    return Math.max(1, Math.ceil((Number(total) || 0) / size));
  }

  function slice(items, page, pageSize) {
    var list = items || [];
    var size = Math.max(1, Number(pageSize) || DEFAULT_SIZE);
    var current = clampPage(page, list.length, size);
    var start = (current - 1) * size;
    return list.slice(start, start + size);
  }

  /* Windowed page numbers: always show the first and last page, the current
     page and its immediate neighbours, and an ellipsis for whatever is
     skipped.  e.g.  1 … 6 [7] 8 … 24 */
  function pageWindow(current, last) {
    if (last <= 7) {
      var all = [];
      for (var i = 1; i <= last; i++) all.push(i);
      return all;
    }
    var pages = [1];
    var from = Math.max(2, current - 1);
    var to = Math.min(last - 1, current + 1);
    if (current <= 3) { from = 2; to = 4; }
    if (current >= last - 2) { from = last - 3; to = last - 1; }
    if (from > 2) pages.push("gap-start");
    for (var p = from; p <= to; p++) pages.push(p);
    if (to < last - 1) pages.push("gap-end");
    pages.push(last);
    return pages;
  }

  function button(nav, icon, label, title) {
    return '<button type="button" class="grac-pager__btn" data-nav="' + nav + '"'
      + ' title="' + title + '" aria-label="' + title + '">'
      + (icon ? '<i class="fa-solid ' + icon + '" aria-hidden="true"></i>' : "")
      + (label ? '<span class="grac-pager__btn-label">' + label + "</span>" : "")
      + "</button>";
  }

  function mount(element, options) {
    if (!element) return null;
    var opts = options || {};
    var sizes = opts.sizes || DEFAULT_SIZES;
    var state = {
      page: Number(opts.page) || 1,
      pageSize: Number(opts.pageSize) || DEFAULT_SIZE,
      total: 0
    };

    element.classList.add("grac-pager");
    element.innerHTML =
      '<div class="grac-pager__info" aria-live="polite"></div>'
      + '<div class="grac-pager__nav" role="navigation" aria-label="Grid pagination">'
      + button("first", "fa-angles-left", "", "First page")
      + button("prev", "fa-chevron-left", "Prev", "Previous page")
      + '<span class="grac-pager__pages"></span>'
      + button("next", "fa-chevron-right", "Next", "Next page")
      + button("last", "fa-angles-right", "", "Last page")
      + "</div>"
      + '<label class="grac-pager__size">Rows'
      + "<select>" + sizes.map(function (size) {
        return '<option value="' + size + '"' + (size === state.pageSize ? " selected" : "") + ">" + size + "</option>";
      }).join("") + "</select></label>";

    var info = element.querySelector(".grac-pager__info");
    var pagesHost = element.querySelector(".grac-pager__pages");
    var sizeSelect = element.querySelector(".grac-pager__size select");
    var navButtons = {};
    ["first", "prev", "next", "last"].forEach(function (nav) {
      navButtons[nav] = element.querySelector('[data-nav="' + nav + '"]');
    });

    function emit() {
      if (typeof opts.onChange === "function") {
        opts.onChange({ page: state.page, pageSize: state.pageSize });
      }
    }

    function goTo(page) {
      var next = clampPage(page, state.total, state.pageSize);
      if (next === state.page) return;
      state.page = next;
      render();
      emit();
    }

    function render() {
      var last = lastPage(state.total, state.pageSize);
      state.page = clampPage(state.page, state.total, state.pageSize);

      var start = state.total ? (state.page - 1) * state.pageSize + 1 : 0;
      var end = Math.min(state.total, state.page * state.pageSize);
      info.innerHTML = state.total
        ? "Showing <b>" + start + "–" + end + "</b> of <b>" + state.total + "</b> records"
        : "No records";

      pagesHost.innerHTML = pageWindow(state.page, last).map(function (entry) {
        if (typeof entry === "string") return '<span class="grac-pager__gap">&hellip;</span>';
        return '<button type="button" class="grac-pager__btn grac-pager__page'
          + (entry === state.page ? " is-active" : "") + '" data-page="' + entry + '"'
          + (entry === state.page ? ' aria-current="page"' : "")
          + ' aria-label="Page ' + entry + '">' + entry + "</button>";
      }).join("");

      navButtons.first.disabled = state.page <= 1;
      navButtons.prev.disabled = state.page <= 1;
      navButtons.next.disabled = state.page >= last;
      navButtons.last.disabled = state.page >= last;
    }

    element.addEventListener("click", function (event) {
      var pageButton = event.target.closest("[data-page]");
      if (pageButton) { goTo(Number(pageButton.dataset.page)); return; }
      var navButton = event.target.closest("[data-nav]");
      if (!navButton || navButton.disabled) return;
      var last = lastPage(state.total, state.pageSize);
      var target = { first: 1, prev: state.page - 1, next: state.page + 1, last: last }[navButton.dataset.nav];
      goTo(target);
    });

    sizeSelect.addEventListener("change", function () {
      state.pageSize = Math.max(1, Number(sizeSelect.value) || DEFAULT_SIZE);
      state.page = 1;
      render();
      emit();
    });

    render();

    return {
      element: element,
      get page() { return state.page; },
      get pageSize() { return state.pageSize; },
      get total() { return state.total; },
      /* Refresh the control after the grid has rendered. Pass whatever is
         known — omitted keys keep their current value. */
      update: function (next) {
        var data = next || {};
        if (data.pageSize != null) {
          state.pageSize = Math.max(1, Number(data.pageSize) || DEFAULT_SIZE);
          if (sizeSelect.value !== String(state.pageSize)) sizeSelect.value = String(state.pageSize);
        }
        if (data.total != null) state.total = Math.max(0, Number(data.total) || 0);
        if (data.page != null) state.page = Number(data.page) || 1;
        element.hidden = state.total === 0 && data.hideWhenEmpty !== false;
        render();
        return state.page;
      },
      reset: function () { state.page = 1; render(); },
      setPage: function (page) { state.page = clampPage(page, state.total, state.pageSize); render(); }
    };
  }

  global.GracPager = {
    mount: mount,
    slice: slice,
    lastPage: lastPage,
    clampPage: clampPage,
    DEFAULT_SIZE: DEFAULT_SIZE,
    DEFAULT_SIZES: DEFAULT_SIZES
  };
})(window);
