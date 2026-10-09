# Icon compatibility across Redmine versions.
# Redmine 6 renders icons via SVG sprite (`sprite_icon`); the old
# `icon icon-*` CSS classes were removed in Redmine 7. This helper uses
# `sprite_icon` when available (Redmine 6/7), and otherwise falls back to the
# plain label (Redmine 5, where the `icon icon-*` class on the link provides
# the icon).
module HelpdeskIconsHelper
  def hd_icon_label(icon, label = nil)
    if respond_to?(:sprite_icon)
      sprite_icon(icon.to_s, label)
    else
      label.to_s.html_safe
    end
  end
end
