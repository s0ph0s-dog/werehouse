"use strict";
async function registerServiceWorker() {
  if ("serviceWorker" in navigator) {
    try {
      const registration = await navigator.serviceWorker.register("/sw.js", {
        scope: "/",
      });
      if (registration.installing) {
        // console.log("Service worker installing");
      } else if (registration.waiting) {
        // console.log("Service worker installed");
      } else if (registration.active) {
        // console.log("Service worker active");
      }
    } catch (error) {
      console.error(`Registration failed with ${error}`);
    }
  }
}

registerServiceWorker();

function tagger_delete(event) {
  event.preventDefault();
  event.stopPropagation();
  const list_item = event.target.closest("li");
  list_item.parentNode.removeChild(list_item);
}

function tagger_make_delete(kind, value) {
  const input = document.createElement("input");
  input.setAttribute("type", "hidden");
  input.setAttribute("name", "delete_" + kind + "s[]");
  input.setAttribute("value", value);
  return input;
}

function tagger_make_row(
  input_type,
  name,
  input_value,
  input_list,
  button_verb,
  button_value
) {
  const li = document.createElement("li");
  const div = document.createElement("div");
  div.setAttribute("class", "input-cell");
  const input = document.createElement("input");
  input.setAttribute("type", input_type);
  input.setAttribute("name", "pending_" + name + "s[]");
  input.setAttribute("value", input_value);
  input.setAttribute("autocomplete", "off");
  input.setAttribute("data-tagger-field", "pending");
  if (input_list) {
    input.setAttribute("list", input_list);
  }
  const button = document.createElement("button");
  button.setAttribute("type", "submit");
  button.setAttribute("name", "delete_pending_" + name);
  button.setAttribute("value", button_value);
  button.setAttribute("data-tagger-btn", "pending");
  button.addEventListener("click", tagger_delete);
  const button_label = document.createTextNode(button_verb);
  li.appendChild(div);
  div.appendChild(input);
  div.appendChild(button);
  button.appendChild(button_label);
  return li;
}

function tagger_find_largest_pending_id(tagger) {
  const pending_elements = tagger.querySelectorAll(
    '[data-tagger-btn="pending"]'
  );
  let max_id = 0;
  for (let el of pending_elements) {
    if (el.value > max_id) {
      max_id = el.value;
    }
  }
  // Intentionally return 0 if no pending IDs exist, so that the first one is 1, because the backend is Lua and 1-indexed.
  return max_id;
}

function tagger_setup(tagger) {
  const name = tagger.dataset.taggerName;
  // The verb to use on the button for each row.
  const button_verb = tagger.dataset.taggerButtonVerb || "Remove";
  // The type to use for the created input elements.
  const input_type = tagger.dataset.inputType || "text";
  // The list to use for autocomplete on the input field.
  const input_list = tagger.dataset.inputList;
  // Where to insert new tags after the user clicks the button or presses enter.
  const insert_mark = tagger.querySelector('[data-tagger-e="insert"]');
  // The text box that new tags are added in.
  const add_field = tagger.querySelector('[data-tagger-field="add"]');
  // A text box near add_field that focus can be quickly swapped to/away from in order to fix autocapitalization in mobile WebKit.
  const add_field_wkfocushack = tagger.querySelector(
    '[data-tagger-field="add-wkhack"]'
  );
  // The button that users click to add a new tag.
  const add_button = tagger.querySelector('[data-tagger-btn="add"]');
  // The div in which to insert hidden form fields that contain the IDs of deleted existing tags.
  const deleted_container = tagger.querySelector('[data-tagger-e="delete"]');
  // All of the buttons for deleting existing tags.
  const delete_buttons = tagger.querySelectorAll('[data-tagger-btn="delete"]');

  function add_pending(event) {
    event.preventDefault();
    event.stopPropagation();
    const next_id = tagger_find_largest_pending_id(tagger) + 1;
    const current_value = add_field.value;
    const row = tagger_make_row(
      input_type,
      name,
      current_value,
      input_list,
      button_verb,
      next_id
    );
    insert_mark.parentNode.insertBefore(row, insert_mark);
    add_field.value = "";
    add_field_wkfocushack.focus();
    add_field.focus();
  }
  add_button.addEventListener("click", add_pending);
  add_field.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      add_pending(event);
    }
  });
  delete_buttons.forEach((btn) => {
    btn.addEventListener("click", (event) => {
      tagger_delete(event);
      const deleted_record = tagger_make_delete(name, event.target.value);
      deleted_container.appendChild(deleted_record);
    });
  });
}

function close_dialog_when_cancel_clicked(content) {
  let cancelButtons = content.querySelectorAll('[name="cancel"]');
  cancelButtons.forEach((btn) => {
    btn.addEventListener("click", (e) => {
      const closest_dialog = btn.closest("dialog");
      if (closest_dialog) {
        closest_dialog.close();
      }
    });
  });
}

function setup_taggers(content) {
  const taggers = content.querySelectorAll("[data-tagger-name]");
  taggers.forEach(tagger_setup);
}

function toggle_video_player_looping(content) {
  document.querySelectorAll("[data-video-loop-toggler]").forEach(el => {
    const vp = document.querySelector("[data-video-loop-toggled]");
    el.addEventListener("change", event => {
      vp.loop = event.srcElement.checked;
    })
  });
}

function prevent_multiple_submits_from_specified_buttons(content) {
  document.querySelectorAll("[data-once]").forEach((el) => {
    const buttons = el.querySelectorAll('input[type="submit"]');
    el.addEventListener("submit", (event) => {
      buttons.forEach((b) => {
        b.setAttribute("aria-disabled", "true");
        b.classList.add("btn-disabled");
        b.addEventListener("click", (event) => {
          if (b.getAttribute("aria-disabled") === "true") {
            event.preventDefault();
            return;
          }
        });
      });
    });
  });
}

function indicate_save_opens_dialog_when_incoming_tags_checked(content) {
  const incoming_tags_list = document.getElementById("incoming_tags_list");
  const save_btn = document.getElementById("save_btn");
  if (save_btn) {
    save_btn.value = "Save";
  }
  if (incoming_tags_list) {
    incoming_tags_list.querySelectorAll("input").forEach((el) => {
      el.addEventListener("change", () => {
        const any_checked = incoming_tags_list.querySelectorAll("input:checked");
        if (any_checked.length > 0) {
          save_btn.value = "Save…";
        } else {
          save_btn.value = "Save";
        }
      });
    });
  }
}

function reorder_group(content) {
  function swap_orders(first_row, second_row) {
    const number_input = 'input[type="number"]';
    const first_order = first_row.querySelector(number_input);
    const second_order = second_row.querySelector(number_input);
    let tmp = first_order.value;
    first_order.value = second_order.value;
    second_order.value = tmp;
  }
  function reorder_up(e) {
    e.preventDefault();
    // Get this tr
    const myself = e.target.closest("tr");
    // Get previous tr
    const previous = myself.previousElementSibling;
    if (previous === null) {
      // If no previous tr, return
      return;
    }
    swap_orders(myself, previous);
    // Move this tr before the previous tr
    previous.before(myself);
  }
  function reorder_down(e) {
    e.preventDefault();
    // Get this tr
    const myself = e.target.closest("tr");
    // Get next tr
    const next_row = myself.nextElementSibling;
    if (next_row === null) {
      // If no previous tr, return
      return;
    }
    swap_orders(myself, next_row);
    // Move this tr before the previous tr
    myself.before(next_row);
  }
  content.querySelectorAll(".reorder-up").forEach((elt) => {
    elt.addEventListener("click", reorder_up);
  });
  content.querySelectorAll(".reorder-down").forEach((elt) => {
    elt.addEventListener("click", reorder_down);
  });
  content.querySelectorAll(".reorder-remove").forEach((elt) => {
    elt.addEventListener("click", (e) => {
      const myself = e.target.closest("tr");
      myself.parentElement.removeChild(myself);
    });
  });
}

function telegram_slow_alert(content) {
  content.querySelectorAll("[data-telegram-slow]").forEach((elt) => {
    elt.addEventListener("click", (e) => {
      setTimeout(() => {
        alert("Telegram is taking a long time to send this one. I'll keep trying in the background. (It might take up to a minute to actually send :/)")
        window.location.reload();
      }, 2000);
    });
  });
}

htmx.onLoad((content) => {
  close_dialog_when_cancel_clicked(content);
  setup_taggers(content);
  toggle_video_player_looping(content);
  prevent_multiple_submits_from_specified_buttons(content);
  indicate_save_opens_dialog_when_incoming_tags_checked(content);
  reorder_group(content);
  telegram_slow_alert(content);
});

// Remove dialogs from the page before saving history, so that they don't end
// up in the bfcache
htmx.on("htmx:beforeHistorySave", () => {
  document.querySelectorAll("dialog").forEach((elt) => {
    elt.innerHtml = "";
    elt.close();
  });
});

htmx.on("htmx:responseError", (e) => {
  console.log(e);
  alert(`That action failed. The server said “${e.detail.xhr.statusText}.”`);
});

htmx.on('htmx:confirm', (evt) => {
  if (evt.explicitOriginalTarget && evt.explicitOriginalTarget.matches("[data-confirm-nicely]")) {
    evt.preventDefault();
    const verb = evt.explicitOriginalTarget.value;
    const form = evt.target;
    const checkboxes = form.querySelectorAll("input[type='checkbox']:checked");
    const names = Array.from(checkboxes).map((box) => {
      return box.nextElementSibling.firstElementChild.textContent || "(error)";
    });
    const name_list = names.reduce(
      (acc, curr) => acc + "\n • " + curr,
      ""
    );
    const confirm_text = `Are you sure you want to ${verb} these ${names.length} items?${name_list}`;
    if (confirm(confirm_text)) {
      evt.detail.issueRequest();
    }
  }
});

let refresherBound = false;
let lostFocusAt = null;
if (!refresherBound) {
  document.addEventListener("visibilitychange", (evt) => {
    if (document.hidden) {
      lostFocusAt = new Date();
    } else {
      const regainedFocusAt = new Date();
      const elapsed = regainedFocusAt - lostFocusAt;
      const dialog = document.getElementsByTagName("dialog")[0];
      if (elapsed > (5 * 60 * 1000) && dialog && !dialog.open) {
        window.location.reload();
      }
    }
  });
  refresherBound = true;
}
// vim: ts=2 sw=2
