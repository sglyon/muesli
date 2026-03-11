from __future__ import annotations

from Cocoa import (
    NSBackingStoreBuffered,
    NSColor,
    NSFont,
    NSMakeRect,
    NSPanel,
    NSScreen,
    NSTextField,
    NSView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorStationary,
    NSFloatingWindowLevel,
    NSWindowStyleMaskBorderless,
)
import objc
from PyObjCTools import AppHelper
import config


STATE_STYLES = {
    "idle": {
        "icon": "🎤",
        "title": "",
        "size": (58, 30),
        "background": (0.10, 0.10, 0.12, 0.66),
        "border": (1.0, 1.0, 1.0, 0.18),
        "icon_color": (1.0, 1.0, 1.0, 0.92),
        "text_color": (1.0, 1.0, 1.0, 0.92),
    },
    "listening": {
        "icon": "🎤",
        "title": "Listening",
        "size": (164, 46),
        "background": (0.83, 0.18, 0.22, 0.94),
        "border": (1.0, 1.0, 1.0, 0.24),
        "icon_color": (1.0, 1.0, 1.0, 1.0),
        "text_color": (1.0, 1.0, 1.0, 1.0),
    },
    "transcribing": {
        "icon": "✍️",
        "title": "Transcribing",
        "size": (182, 46),
        "background": (0.83, 0.60, 0.11, 0.94),
        "border": (1.0, 1.0, 1.0, 0.24),
        "icon_color": (0.10, 0.08, 0.05, 0.95),
        "text_color": (0.10, 0.08, 0.05, 0.95),
    },
    "meeting": {
        "icon": "📝",
        "title": "Meeting",
        "size": (146, 46),
        "background": (0.14, 0.62, 0.38, 0.94),
        "border": (1.0, 1.0, 1.0, 0.24),
        "icon_color": (1.0, 1.0, 1.0, 1.0),
        "text_color": (1.0, 1.0, 1.0, 1.0),
    },
    "processing": {
        "icon": "⚙️",
        "title": "Processing",
        "size": (170, 46),
        "background": (0.17, 0.28, 0.74, 0.94),
        "border": (1.0, 1.0, 1.0, 0.24),
        "icon_color": (1.0, 1.0, 1.0, 1.0),
        "text_color": (1.0, 1.0, 1.0, 1.0),
    },
}


def _ns_color(rgba: tuple[float, float, float, float]):
    return NSColor.colorWithRed_green_blue_alpha_(*rgba)


class IndicatorView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(IndicatorView, self).initWithFrame_(frame)
        if self is None:
            return None

        self.setWantsLayer_(True)
        self.owner = None
        self._drag_offset = None

        self.icon_label = self._make_label(frame, 18, True)
        self.text_label = self._make_label(frame, 13, False)
        self.addSubview_(self.icon_label)
        self.addSubview_(self.text_label)
        self.apply_style("idle")
        return self

    def _make_label(self, frame, font_size: int, bold: bool):
        label = NSTextField.alloc().initWithFrame_(frame)
        label.setBezeled_(False)
        label.setDrawsBackground_(False)
        label.setEditable_(False)
        label.setSelectable_(False)
        label.setBordered_(False)
        label.setAlignment_(1)
        font = NSFont.boldSystemFontOfSize_(font_size) if bold else NSFont.systemFontOfSize_(font_size)
        label.setFont_(font)
        return label

    def apply_style(self, state: str):
        style = STATE_STYLES.get(state, STATE_STYLES["idle"])
        width, height = style["size"]

        layer = self.layer()
        layer.setCornerRadius_(height / 2)
        layer.setBackgroundColor_(_ns_color(style["background"]).CGColor())
        layer.setBorderWidth_(1.0)
        layer.setBorderColor_(_ns_color(style["border"]).CGColor())

        self.icon_label.setStringValue_(style["icon"])
        self.icon_label.setTextColor_(_ns_color(style["icon_color"]))
        if state == "idle":
            icon_width = 26
            self.icon_label.setFrame_(
                NSMakeRect((width - icon_width) / 2, 5, icon_width, max(height - 10, 18))
            )
        else:
            self.icon_label.setFrame_(NSMakeRect(12, 9, 24, max(height - 18, 18)))

        self.text_label.setStringValue_(style["title"])
        self.text_label.setTextColor_(_ns_color(style["text_color"]))
        self.text_label.setHidden_(not bool(style["title"]))
        self.text_label.setFrame_(NSMakeRect(40, 12, max(width - 52, 0), max(height - 20, 16)))

    def mouseDown_(self, event):
        if self.owner is None:
            return
        window = self.window()
        if window is None:
            return
        frame = window.frame()
        screen_point = window.convertPointToScreen_(event.locationInWindow())
        self._drag_offset = (
            screen_point.x - frame.origin.x,
            screen_point.y - frame.origin.y,
        )

    def mouseDragged_(self, event):
        if self.owner is None or self._drag_offset is None:
            return
        window = self.window()
        if window is None:
            return
        screen_point = window.convertPointToScreen_(event.locationInWindow())
        self.owner.move_to_origin(
            screen_point.x - self._drag_offset[0],
            screen_point.y - self._drag_offset[1],
        )

    def mouseUp_(self, event):
        if self.owner is not None:
            self.owner.persist_current_origin()
        self._drag_offset = None

    def hitTest_(self, point):
        return self


class FloatingIndicator:
    """Small always-on-top status pill anchored to the right edge of the screen."""

    EDGE_MARGIN = 6
    DEFAULT_Y_RATIO = 0.56

    def __init__(self):
        self.panel: NSPanel | None = None
        self.view: IndicatorView | None = None
        self.state = "idle"
        cfg = config.load()
        self._manual_origin = self._load_origin(cfg.get("indicator_origin"))
        AppHelper.callAfter(self._create_panel)

    def _load_origin(self, value):
        if not isinstance(value, (list, tuple)) or len(value) != 2:
            return None
        try:
            return float(value[0]), float(value[1])
        except (TypeError, ValueError):
            return None

    def _create_panel(self):
        if self.panel is not None:
            return

        width, height = STATE_STYLES["idle"]["size"]
        frame = self._frame_for_size(width, height)
        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            frame,
            NSWindowStyleMaskBorderless,
            NSBackingStoreBuffered,
            False,
        )
        self.panel.setLevel_(NSFloatingWindowLevel)
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setHasShadow_(True)
        self.panel.setHidesOnDeactivate_(False)
        self.panel.setIgnoresMouseEvents_(False)
        self.panel.setMovableByWindowBackground_(False)
        self.panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorStationary
        )

        self.view = IndicatorView.alloc().initWithFrame_(NSMakeRect(0, 0, width, height))
        self.view.owner = self
        self.panel.setContentView_(self.view)
        self.panel.orderFrontRegardless()
        self._apply_state(self.state)

    def _visible_frame(self):
        screen = NSScreen.mainScreen()
        if screen is None:
            return None
        return screen.visibleFrame()

    def _frame_for_size(self, width: float, height: float):
        visible = self._visible_frame()
        if visible is None:
            return NSMakeRect(0, 0, width, height)

        if self._manual_origin is not None:
            x, y = self._clamp_origin(self._manual_origin[0], self._manual_origin[1], width, height)
        else:
            x = visible.origin.x + visible.size.width - width - self.EDGE_MARGIN
            y = visible.origin.y + (visible.size.height * self.DEFAULT_Y_RATIO) - (height / 2)
            x, y = self._clamp_origin(x, y, width, height)
        return NSMakeRect(x, y, width, height)

    def _clamp_origin(self, x: float, y: float, width: float, height: float):
        visible = self._visible_frame()
        if visible is None:
            return x, y

        min_x = visible.origin.x
        max_x = visible.origin.x + visible.size.width - width
        min_y = visible.origin.y
        max_y = visible.origin.y + visible.size.height - height
        return (
            min(max(x, min_x), max_x),
            min(max(y, min_y), max_y),
        )

    def _apply_state(self, state: str):
        self.state = state if state in STATE_STYLES else "idle"
        if self.panel is None or self.view is None:
            self._create_panel()
            return

        style = STATE_STYLES[self.state]
        width, height = style["size"]
        self.view.setFrame_(NSMakeRect(0, 0, width, height))
        self.view.apply_style(self.state)
        self.panel.setFrame_display_(
            self._frame_for_size(width, height),
            True,
        )
        self.panel.setAlphaValue_(0.82 if self.state == "idle" else 1.0)
        self.panel.orderFrontRegardless()

    def set_state(self, state: str):
        AppHelper.callAfter(self._apply_state, state)

    def ensure_visible(self):
        AppHelper.callAfter(self._apply_state, self.state)

    def move_to_origin(self, x: float, y: float):
        if self.panel is None:
            return
        frame = self.panel.frame()
        clamped_x, clamped_y = self._clamp_origin(x, y, frame.size.width, frame.size.height)
        self.panel.setFrameOrigin_((clamped_x, clamped_y))

    def persist_current_origin(self):
        if self.panel is None:
            return
        frame = self.panel.frame()
        self._manual_origin = (frame.origin.x, frame.origin.y)
        cfg = config.load()
        cfg["indicator_origin"] = [frame.origin.x, frame.origin.y]
        config.save(cfg)

    def close(self):
        if self.panel is not None:
            AppHelper.callAfter(self.panel.close)
