#include "windowframe_win.h"

#include <QCoreApplication>
#include <QDebug>
#include <QQuickItem>
#include <QQuickWindow>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

namespace {
constexpr UINT_PTR frameId = 1;

struct ResizeBorder {
    int horizontal;
    int vertical;
};

ResizeBorder resizeBorder(HWND hwnd)
{
    const auto dpi = GetDpiForWindow(hwnd);
    const auto padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    return {GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) + padding,
            GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) + padding};
}

LRESULT hitTest(HWND hwnd, LPARAM position, const QQuickWindow &window, const QQuickItem &dragArea)
{
    if (IsIconic(hwnd))
        return HTCLIENT;

    POINT point{GET_X_LPARAM(position), GET_Y_LPARAM(position)};
    if (!IsZoomed(hwnd)) {
        RECT frame{};
        GetWindowRect(hwnd, &frame);
        const auto border = resizeBorder(hwnd);
        const bool left = point.x < frame.left + border.horizontal;
        const bool right = point.x >= frame.right - border.horizontal;
        if (point.y < frame.top + border.vertical)
            return left ? HTTOPLEFT : right ? HTTOPRIGHT : HTTOP;
        if (point.y >= frame.bottom - border.vertical)
            return left ? HTBOTTOMLEFT : right ? HTBOTTOMRIGHT : HTBOTTOM;
        if (left || right)
            return left ? HTLEFT : HTRIGHT;
    }

    ScreenToClient(hwnd, &point);
    const auto scale = window.devicePixelRatio();
    const auto local = dragArea.mapFromScene({point.x / scale, point.y / scale});
    return dragArea.isEnabled() && dragArea.contains(local) ? HTCAPTION : HTCLIENT;
}

void extendFrame(HWND hwnd)
{
    const MARGINS margins{1, 1, 1, 1};
    DwmExtendFrameIntoClientArea(hwnd, &margins);
}

LRESULT CALLBACK windowFrameProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam,
                                 UINT_PTR id, DWORD_PTR data)
{
    const auto &dragArea = *reinterpret_cast<QQuickItem *>(data);
    switch (message) {
    case WM_NCCALCSIZE:
        if (wParam) {
            if (IsZoomed(hwnd)) {
                // Preserve the native maximized side and bottom insets, but
                // leave only the resize border at the top, without a caption.
                auto &rect = reinterpret_cast<NCCALCSIZE_PARAMS *>(lParam)->rgrc[0];
                const auto top = rect.top;
                DefSubclassProc(hwnd, message, wParam, lParam);
                rect.top = top + resizeBorder(hwnd).vertical;
            }
            return 0;
        }
        break;
    case WM_NCHITTEST:
        if (const auto *window = dragArea.window())
            return hitTest(hwnd, lParam, *window, dragArea);
        break;
    case WM_DWMCOMPOSITIONCHANGED:
        extendFrame(hwnd);
        break;
    case WM_NCDESTROY:
        RemoveWindowSubclass(hwnd, windowFrameProc, id);
        break;
    }
    return DefSubclassProc(hwnd, message, wParam, lParam);
}

LPARAM screenPosition(HWND hwnd, QPoint point)
{
    POINT screen{point.x(), point.y()};
    ClientToScreen(hwnd, &screen);
    return MAKELPARAM(screen.x, screen.y);
}

LRESULT hitAt(HWND hwnd, QPoint point)
{
    return SendMessageW(hwnd, WM_NCHITTEST, 0, screenPosition(hwnd, point));
}
}

bool installWindowFrame(QQuickWindow &window)
{
    auto *dragArea = window.findChild<QQuickItem *>("windowDragArea");
    if (!dragArea)
        return false;

    const auto hwnd = reinterpret_cast<HWND>(window.winId());
    if (!SetWindowSubclass(hwnd, windowFrameProc, frameId, reinterpret_cast<DWORD_PTR>(dragArea)))
        return false;

    QObject::connect(dragArea, &QObject::destroyed, &window, [hwnd] {
        RemoveWindowSubclass(hwnd, windowFrameProc, frameId);
    });
    extendFrame(hwnd);
    const DWM_WINDOW_CORNER_PREFERENCE corners = DWMWCP_ROUND;
    DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
    const COLORREF border = DWMWA_COLOR_NONE;
    DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, &border, sizeof(border));
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    return true;
}

bool verifyWindowFrame(QQuickWindow &window)
{
    auto *area = window.findChild<QQuickItem *>("windowDragArea");
    auto *minimize = window.findChild<QQuickItem *>("minimizeWindowButton");
    auto *maximize = window.findChild<QQuickItem *>("maximizeWindowButton");
    auto *close = window.findChild<QQuickItem *>("closeWindowButton");
    if (!area || !minimize || !maximize || !close) {
        qWarning() << "Window controls unavailable:" << area << minimize << maximize << close;
        return false;
    }

    const auto hwnd = reinterpret_cast<HWND>(window.winId());
    // A smoke test process can start with SW_HIDE in STARTUPINFO. Qt will
    // render it, but Win32 refuses state changes until the HWND is shown.
    if (!IsWindowVisible(hwnd))
        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    QCoreApplication::processEvents();
    const auto scale = window.devicePixelRatio();
    area->parentItem()->ensurePolished();
    minimize->parentItem()->ensurePolished();
    const auto pointOn = [scale](const QQuickItem *item) {
        return (item->mapToScene({item->width() / 2, item->height() / 2}) * scale).toPoint();
    };
    RECT client{};
    GetClientRect(hwnd, &client);
    const auto caption = hitAt(hwnd, pointOn(area));
    const auto minButton = hitAt(hwnd, pointOn(minimize));
    const auto maxButton = hitAt(hwnd, pointOn(maximize));
    const auto closeButton = hitAt(hwnd, pointOn(close));
    const auto topLeft = hitAt(hwnd, {0, 0});
    const auto bottomRight = hitAt(hwnd, {client.right - 1, client.bottom - 1});
    const auto right = hitAt(hwnd, {client.right - 1, client.bottom / 2});
    if (!(GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_THICKFRAME) || caption != HTCAPTION ||
        minButton != HTCLIENT || maxButton != HTCLIENT || closeButton != HTCLIENT ||
        topLeft != HTTOPLEFT || bottomRight != HTBOTTOMRIGHT || right != HTRIGHT) {
        qWarning() << "Window hit test failed:" << caption << minButton << maxButton << closeButton
                   << topLeft << bottomRight << right << "DPI scale:" << scale << client.right << client.bottom
                   << "title:" << area->size() << pointOn(area)
                   << "buttons:" << minimize->size() << pointOn(minimize) << pointOn(maximize) << pointOn(close)
                   << "visible:" << minimize->isVisible() << window.size();
        return false;
    }

    SendMessageW(hwnd, WM_NCLBUTTONDBLCLK, HTCAPTION, screenPosition(hwnd, pointOn(area)));
    QCoreApplication::processEvents();
    const bool doubleClickMaximized = IsZoomed(hwnd) && hitAt(hwnd, pointOn(area)) == HTCAPTION;
    SendMessageW(hwnd, WM_NCLBUTTONDBLCLK, HTCAPTION, screenPosition(hwnd, pointOn(area)));
    QCoreApplication::processEvents();
    const bool doubleClickRestored = !IsZoomed(hwnd);

    if (!QMetaObject::invokeMethod(maximize, "clicked"))
        return false;
    QCoreApplication::processEvents();
    const bool maximized = IsZoomed(hwnd) && hitAt(hwnd, pointOn(area)) == HTCAPTION;
    if (!QMetaObject::invokeMethod(maximize, "clicked"))
        return false;
    QCoreApplication::processEvents();
    const bool restored = !IsZoomed(hwnd) && hitAt(hwnd, {0, 0}) == HTTOPLEFT;
    if (!QMetaObject::invokeMethod(minimize, "clicked"))
        return false;
    QCoreApplication::processEvents();
    const bool minimized = IsIconic(hwnd);
    window.showNormal();
    QCoreApplication::processEvents();
    const bool passed = doubleClickMaximized && doubleClickRestored && maximized && restored && minimized && !IsIconic(hwnd);
    if (passed)
        qInfo("Window frame checks passed: caption, buttons, corner resizing, double-click, maximize, restore and minimize.");
    else
        qWarning() << "Window transitions failed:" << doubleClickMaximized << doubleClickRestored
                   << maximized << restored << minimized << !IsIconic(hwnd);
    return passed;
}
