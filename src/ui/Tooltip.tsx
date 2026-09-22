import React, { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { theme } from './theme';

export const TOOLTIP_GAP = 8;
export const TOOLTIP_SHOW_DELAY_MS = 500;
const ESTIMATED_TOOLTIP_HEIGHT = 36;

const tooltipBubbleStyle = (
  multiline: boolean,
  maxWidth: number
): React.CSSProperties => ({
  position: 'fixed',
  zIndex: 10000,
  pointerEvents: 'none',
  padding: '6px 10px',
  borderRadius: '10px',
  backgroundColor: theme.colors.surface,
  border: `1px solid ${theme.colors.border}`,
  boxShadow: '0 10px 28px rgba(0, 0, 0, 0.55)',
  color: theme.colors.text.primary,
  fontSize: '11px',
  fontWeight: 500,
  fontFamily: theme.fonts.display,
  lineHeight: 1.4,
  whiteSpace: multiline ? 'normal' : 'nowrap',
  maxWidth,
  textAlign: 'center',
  ...(multiline
    ? {
        display: 'block',
        overflowWrap: 'anywhere',
        wordBreak: 'break-word',
        boxSizing: 'border-box',
      }
    : {}),
});

interface FloatingTooltipProps {
  label: string;
  x: number;
  y: number;
  placement?: 'top' | 'bottom';
  multiline?: boolean;
  maxWidth?: number;
}

/** Tooltip anchored to viewport coordinates (used for native drag-handle hover). */
export const FloatingTooltip: React.FC<FloatingTooltipProps> = ({
  label,
  x,
  y,
  placement = 'bottom',
  multiline = false,
  maxWidth = 240,
}) => {
  if (!label) return null;

  const node = (
    <span
      role="tooltip"
      style={{
        ...tooltipBubbleStyle(multiline, maxWidth),
        left: x,
        top: y,
        transform:
          placement === 'top'
            ? `translate(-50%, calc(-100% - ${TOOLTIP_GAP}px))`
            : `translate(-50%, ${TOOLTIP_GAP}px)`,
      }}
    >
      {label}
    </span>
  );

  return typeof document !== 'undefined' ? createPortal(node, document.body) : null;
};

type TooltipChildProps = React.HTMLAttributes<HTMLElement> & {
  'aria-label'?: string;
};

interface TooltipProps {
  label: string;
  children: React.ReactElement<TooltipChildProps>;
  placement?: 'top' | 'bottom';
  multiline?: boolean;
  maxWidth?: number;
  /** Milliseconds to wait before showing after hover/focus. */
  showDelayMs?: number;
  /** Applied to the outer wrapper (e.g. absolute positioning for nav icons). */
  wrapperStyle?: React.CSSProperties;
}

/**
 * In-app tooltip — replaces native `title` popovers that are unreadable in WKWebView panels.
 * Uses fixed positioning + portal; flips below anchors near the window top edge.
 */
export const Tooltip: React.FC<TooltipProps> = ({
  label,
  children,
  placement = 'top',
  multiline = false,
  maxWidth = 240,
  showDelayMs = TOOLTIP_SHOW_DELAY_MS,
  wrapperStyle,
}) => {
  const anchorRef = useRef<HTMLSpanElement>(null);
  const showTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [visible, setVisible] = useState(false);
  const [coords, setCoords] = useState({ x: 0, y: 0 });
  const [resolvedPlacement, setResolvedPlacement] = useState<'top' | 'bottom'>('top');

  const resolvePlacement = useCallback(
    (rect: DOMRect, preferred: 'top' | 'bottom'): 'top' | 'bottom' => {
      const minSpace = ESTIMATED_TOOLTIP_HEIGHT + TOOLTIP_GAP + 6;
      const spaceAbove = rect.top;
      const spaceBelow = window.innerHeight - rect.bottom;

      if (preferred === 'top' && spaceAbove < minSpace) {
        return 'bottom';
      }
      if (preferred === 'bottom' && spaceBelow < minSpace) {
        return 'top';
      }
      return preferred;
    },
    []
  );

  const updateCoords = useCallback(() => {
    const el = anchorRef.current;
    if (!el) return;
    const rect = el.getBoundingClientRect();
    const side = resolvePlacement(rect, placement);
    setResolvedPlacement(side);
    setCoords({
      x: rect.left + rect.width / 2,
      y: side === 'top' ? rect.top : rect.bottom,
    });
  }, [placement, resolvePlacement]);

  const hide = useCallback(() => {
    if (showTimeoutRef.current) {
      clearTimeout(showTimeoutRef.current);
      showTimeoutRef.current = null;
    }
    setVisible(false);
  }, []);

  const scheduleShow = useCallback(() => {
    if (showTimeoutRef.current) {
      clearTimeout(showTimeoutRef.current);
    }
    showTimeoutRef.current = setTimeout(() => {
      showTimeoutRef.current = null;
      updateCoords();
      setVisible(true);
    }, showDelayMs);
  }, [showDelayMs, updateCoords]);

  useEffect(() => () => hide(), [hide]);

  const child = React.cloneElement<TooltipChildProps>(children, {
    title: undefined,
    'aria-label': children.props['aria-label'] ?? label,
    onMouseEnter: (e: React.MouseEvent<HTMLElement>) => {
      scheduleShow();
      children.props.onMouseEnter?.(e);
    },
    onMouseLeave: (e: React.MouseEvent<HTMLElement>) => {
      hide();
      children.props.onMouseLeave?.(e);
    },
    onFocus: (e: React.FocusEvent<HTMLElement>) => {
      scheduleShow();
      children.props.onFocus?.(e);
    },
    onBlur: (e: React.FocusEvent<HTMLElement>) => {
      hide();
      children.props.onBlur?.(e);
    },
  });

  const tooltipNode =
    visible && label ? (
      <span
        role="tooltip"
        style={{
          ...tooltipBubbleStyle(multiline, maxWidth),
          left: coords.x,
          top: coords.y,
          transform:
            resolvedPlacement === 'top'
              ? `translate(-50%, calc(-100% - ${TOOLTIP_GAP}px))`
              : `translate(-50%, ${TOOLTIP_GAP}px)`,
        }}
      >
        {label}
      </span>
    ) : null;

  return (
    <>
      <span
        ref={anchorRef}
        style={{
          position: 'relative',
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          verticalAlign: 'inherit',
          ...wrapperStyle,
        }}
      >
        {child}
      </span>
      {typeof document !== 'undefined' && tooltipNode
        ? createPortal(tooltipNode, document.body)
        : null}
    </>
  );
};

export default Tooltip;
