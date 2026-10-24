import React, { useCallback, useEffect, useRef, useState } from 'react';
import { usePomodoroStore } from '../state/pomodoroStore';
import { useTaskStore } from '../state/taskStore';
import { initPersistence } from '../services/persistence';
import { NativeBridge } from '../services/nativeBridge';
import TimerView from './TimerView';
import Controls from './Controls';
import SettingsView from './SettingsView';
import ReportsView from './ReportsView';
import TaskShelf from './TaskShelf';
import AgentProposalOverlay, { AgentProposal } from './AgentProposalOverlay';
import {
  ProposalSettlement,
  QueuedProposal,
  dismissProposal,
  enqueueProposal,
  markApplying,
  settleProposal,
  syncPendingProposals,
} from './agentProposalQueue';
import { handleNativeAgentCommand } from '../services/agentCommandAdapter';
import Tooltip, { FloatingTooltip } from './Tooltip';
import { theme } from './theme';

const BlobBackground: React.FC<{ color: string; isBreak: boolean }> = ({ color, isBreak }) => {
  return (
    <div style={{
      position: 'absolute',
      top: 0,
      left: 0,
      width: '100%',
      height: '100%',
      zIndex: 0,
      overflow: 'hidden',
      pointerEvents: 'none',
      animation: isBreak ? 'breath-sync 19s infinite ease-in-out' : 'none',
    }}>
      <style>
        {`
          @keyframes blob-float-1 {
            0% { transform: translate(-20%, -20%) scale(1); rotate: 0deg; }
            33% { transform: translate(20%, 10%) scale(1.1); rotate: 120deg; }
            66% { transform: translate(-10%, 30%) scale(0.9); rotate: 240deg; }
            100% { transform: translate(-20%, -20%) scale(1); rotate: 360deg; }
          }
          @keyframes blob-float-2 {
            0% { transform: translate(30%, 30%) scale(1.1); rotate: 0deg; }
            33% { transform: translate(-10%, -20%) scale(0.9); rotate: -120deg; }
            66% { transform: translate(20%, -30%) scale(1.2); rotate: -240deg; }
            100% { transform: translate(30%, 30%) scale(1.1); rotate: -360deg; }
          }
          @keyframes blob-float-3 {
            0% { transform: translate(-30%, 20%) scale(0.9); rotate: 0deg; }
            50% { transform: translate(30%, -10%) scale(1.1); rotate: 180deg; }
            100% { transform: translate(-30%, 20%) scale(0.9); rotate: 360deg; }
          }
          @keyframes breath-sync {
            0%, 100% { transform: scale(1); opacity: 0.8; }
            21% { transform: scale(1.2); opacity: 1; }
            58% { transform: scale(1.2); opacity: 1; }
          }
        `}
      </style>
      <div style={{
        position: 'absolute',
        top: '20%',
        left: '20%',
        width: '350px',
        height: '350px',
        background: color,
        filter: 'blur(80px)',
        opacity: 0.15,
        borderRadius: '40% 60% 70% 30% / 40% 50% 60% 50%',
        animation: 'blob-float-1 25s infinite linear',
      }} />
      <div style={{
        position: 'absolute',
        top: '40%',
        left: '50%',
        width: '300px',
        height: '300px',
        background: color,
        filter: 'blur(100px)',
        opacity: 0.12,
        borderRadius: '60% 40% 30% 70% / 50% 30% 70% 50%',
        animation: 'blob-float-2 30s infinite linear',
      }} />
      <div style={{
        position: 'absolute',
        bottom: '10%',
        right: '10%',
        width: '400px',
        height: '400px',
        background: color,
        filter: 'blur(90px)',
        opacity: 0.1,
        borderRadius: '30% 70% 50% 50% / 50% 60% 40% 50%',
        animation: 'blob-float-3 35s infinite linear',
      }} />
    </div>
  );
};

const App: React.FC = () => {
  const tick = usePomodoroStore((state) => state.tick);
  const startTimer = usePomodoroStore((state) => state.startTimer);
  const pauseTimer = usePomodoroStore((state) => state.pauseTimer);
  const skipTimer = usePomodoroStore((state) => state.skipTimer);
  const resetTimer = usePomodoroStore((state) => state.resetTimer);
  const timerStatus = usePomodoroStore((state) => state.timer.status);
  const config = usePomodoroStore((state) => state.config);
  const focusInCycleCount = usePomodoroStore((state) => state.session.focusInCycleCount);
  const sessionType = usePomodoroStore((state) => state.session.type);

  const { tasks, activeTaskId } = useTaskStore();
  const activeTask = tasks.find(t => t.id === activeTaskId);

  const [showSettings, setShowSettings] = useState(false);
  const [showReports, setShowReports] = useState(false);
  const [showTasks, setShowTasks] = useState(false);
  const [agentProposals, setAgentProposals] = useState<QueuedProposal[]>([]);
  const [isCelebrating, setIsCelebrating] = useState(false);
  const [isPinned, setIsPinned] = useState(false);
  const [dragHandleTooltip, setDragHandleTooltip] = useState<{ x: number; y: number } | null>(null);
  const dragGripRef = useRef<HTMLDivElement>(null);

  const handleCloseTasks = () => {
    setShowTasks(false);
  };

  const handleTogglePin = () => {
    NativeBridge.togglePinned();
  };

  useEffect(() => {
    initPersistence();
    const interval = setInterval(() => tick(), 100);
    
    // Request initial pinned state from native
    NativeBridge.getPinnedState();
    
    return () => clearInterval(interval);
  }, [tick]);

  // Listen for pinned state changes from native
  useEffect(() => {
    const handlePinnedStateChanged = (event: any) => {
      const { isPinned: pinned } = event.detail;
      setIsPinned(pinned);
      if (!pinned) setDragHandleTooltip(null);
    };

    window.addEventListener('native:pinnedStateChanged' as any, handlePinnedStateChanged);
    return () => {
      window.removeEventListener('native:pinnedStateChanged' as any, handlePinnedStateChanged);
    };
  }, []);

  // Drag-handle tooltip (native overlay blocks React hover; position from grip DOM rect)
  useEffect(() => {
    const handleDragHandleTooltip = (event: CustomEvent<{ show: boolean }>) => {
      if (!event.detail.show) {
        setDragHandleTooltip(null);
        return;
      }
      const grip = dragGripRef.current;
      if (!grip) return;
      const rect = grip.getBoundingClientRect();
      setDragHandleTooltip({
        x: rect.left + rect.width / 2,
        y: rect.bottom,
      });
    };

    window.addEventListener('native:dragHandleTooltip' as any, handleDragHandleTooltip);
    return () => {
      window.removeEventListener('native:dragHandleTooltip' as any, handleDragHandleTooltip);
    };
  }, []);

  // Listen for native menu actions and task completion
  useEffect(() => {
    const handleMenuAction = (event: any) => {
      const { type } = event.detail;
      
      switch (type) {
        case 'toggle':
          if (timerStatus === 'running') {
            pauseTimer();
          } else {
            if (config.soundEnabled) NativeBridge.playClickSound();
            startTimer();
          }
          break;
        case 'skip':
          skipTimer();
          break;
        case 'reset':
          resetTimer();
          break;
      }
    };

    const handleTaskCompletion = () => {
      setIsCelebrating(true);
      setTimeout(() => setIsCelebrating(false), 2000);
    };

    const handleWindowHidden = () => {
      setShowSettings(false);
      setShowReports(false);
      setShowTasks(false);
      setDragHandleTooltip(null);
    };

    window.addEventListener('native:menuAction' as any, handleMenuAction);
    window.addEventListener('task-completed' as any, handleTaskCompletion);
    window.addEventListener('native:windowHidden' as any, handleWindowHidden);
    window.addEventListener('native:agentCommand' as any, handleNativeAgentCommand);
    
    // Handle app activation to catch up on timer state
    const handleAppActivation = () => {
      try {
        console.log('App: Received activation signal, ticking timer');
        tick();
      } catch (error) {
        console.error('App: Error during activation tick:', error);
      }
      NativeBridge.getPendingAgentProposals();
    };
    window.addEventListener('native:appDidBecomeActive' as any, handleAppActivation);
    
    return () => {
      window.removeEventListener('native:menuAction' as any, handleMenuAction);
      window.removeEventListener('task-completed' as any, handleTaskCompletion);
      window.removeEventListener('native:windowHidden' as any, handleWindowHidden);
      window.removeEventListener('native:agentCommand' as any, handleNativeAgentCommand);
      window.removeEventListener('native:appDidBecomeActive' as any, handleAppActivation);
    };
  }, [timerStatus, startTimer, pauseTimer, skipTimer, resetTimer, config.soundEnabled, tick]);

  // Agent proposals: native owns the pending set; this queue mirrors it and keeps
  // approved cards on screen until native reports whether the write landed.
  useEffect(() => {
    const handleProposal = (event: Event) => {
      const detail = (event as CustomEvent).detail as AgentProposal | undefined;
      if (detail?.requestId) setAgentProposals((queue) => enqueueProposal(queue, detail));
    };
    const handlePending = (event: Event) => {
      const proposals = (event as CustomEvent).detail?.proposals;
      if (Array.isArray(proposals)) setAgentProposals((queue) => syncPendingProposals(queue, proposals));
    };
    const handleSettled = (event: Event) => {
      const detail = (event as CustomEvent).detail as ProposalSettlement | undefined;
      if (detail?.requestId) setAgentProposals((queue) => settleProposal(queue, detail));
    };

    window.addEventListener('native:agentProposal', handleProposal);
    window.addEventListener('native:pendingAgentProposals', handlePending);
    window.addEventListener('native:agentProposalSettled', handleSettled);
    NativeBridge.getPendingAgentProposals();

    return () => {
      window.removeEventListener('native:agentProposal', handleProposal);
      window.removeEventListener('native:pendingAgentProposals', handlePending);
      window.removeEventListener('native:agentProposalSettled', handleSettled);
    };
  }, []);

  const handleProposalApproving = useCallback((requestId: string) => {
    setAgentProposals((queue) => markApplying(queue, requestId));
  }, []);

  const handleProposalDismiss = useCallback((requestId: string) => {
    setAgentProposals((queue) => dismissProposal(queue, requestId));
  }, []);

  const visibleProposal = agentProposals[0];

  // Local keyboard shortcuts (Space for start/pause, Esc for hide, Cmd+Shift+P for pin)
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      // Don't trigger if user is typing in an input or textarea
      const target = event.target as HTMLElement;
      const isInput = target.tagName === 'INPUT' || 
                      target.tagName === 'TEXTAREA' || 
                      target.isContentEditable;
      
      if (isInput) return;

      // Cmd+Shift+P to toggle pin
      if (event.code === 'KeyP' && event.metaKey && event.shiftKey) {
        event.preventDefault();
        NativeBridge.togglePinned();
        return;
      }

      if (event.code === 'Space') {
        event.preventDefault(); // Prevent page scroll
        if (timerStatus === 'running') {
          pauseTimer();
        } else {
          if (config.soundEnabled) NativeBridge.playClickSound();
          startTimer();
        }
      } else if (event.code === 'Escape') {
        // If pinned, Escape will unpin; if not pinned, it will hide
        if (isPinned) {
          NativeBridge.setPinned(false);
        } else {
          NativeBridge.hideWindow();
        }
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [timerStatus, startTimer, pauseTimer, config.soundEnabled, isPinned]);

  const getThemeColor = () => {
    if (isCelebrating) return '#FFD700'; // Gold celebration glow
    switch (sessionType) {
      case 'focus': return theme.colors.focus.primary;
      case 'shortBreak': return theme.colors.shortBreak.primary;
      case 'longBreak': return theme.colors.longBreak.primary;
    }
  };

  return (
    <div style={{ 
      display: 'flex', 
      flexDirection: 'column', 
      height: '100%',
      width: '100%',
      backgroundColor: theme.colors.background,
      position: 'relative',
      overflow: 'hidden',
      fontFamily: theme.fonts.display,
      // Subtle pinned indicator - golden glow around the edges
      boxShadow: isPinned 
        ? 'inset 0 0 0 1px rgba(255, 215, 0, 0.15), inset 0 0 30px rgba(255, 215, 0, 0.05)' 
        : 'none',
      transition: 'box-shadow 0.3s ease-out',
    }}>
      <style>
        {`
          /* Hide scrollbar for Chrome, Safari and Opera */
          *::-webkit-scrollbar {
            display: none;
          }
          /* Hide scrollbar for IE, Edge and Firefox */
          * {
            -ms-overflow-style: none;  /* IE and Edge */
            scrollbar-width: none;  /* Firefox */
          }
          /* Disable Rubber-banding / Elastic Scrolling on root */
          html, body {
            overscroll-behavior: none;
            overflow: hidden;
            height: 100vh;
            width: 100vw;
            position: fixed;
            margin: 0;
            padding: 0;
            -webkit-user-select: none;
            user-select: none;
          }
          #root {
            height: 100vh;
            width: 100vw;
            overflow: hidden;
          }
        `}
      </style>
      <BlobBackground 
        color={getThemeColor()} 
        isBreak={sessionType !== 'focus'} 
      />

      {isPinned && (
        <div
          ref={dragGripRef}
          role="presentation"
          aria-hidden
          style={{
            position: 'absolute',
            top: '18px',
            left: '50%',
            transform: 'translateX(-50%)',
            zIndex: 5,
            display: 'flex',
            alignItems: 'center',
            gap: '4px',
            pointerEvents: 'none',
          }}
        >
          {[0, 1, 2].map((i) => (
            <div
              key={i}
              style={{
                width: '3px',
                height: '3px',
                borderRadius: '50%',
                backgroundColor: theme.colors.text.secondary,
                opacity: 0.45,
              }}
            />
          ))}
        </div>
      )}

      {/* Top Navigation */}
      <Tooltip label="Reports" placement="bottom" wrapperStyle={reportsButtonAnchorStyle}>
        <button 
          onClick={() => setShowReports(true)}
          style={iconButtonStyle}
          onMouseEnter={(e) => (e.currentTarget.style.opacity = '1')}
          onMouseLeave={(e) => (e.currentTarget.style.opacity = '0.3')}
          aria-label="Reports"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
            <line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/>
          </svg>
        </button>
      </Tooltip>

      {/* Pin Button */}
      <Tooltip label={isPinned ? 'Unpin from screen (⇧⌘P)' : 'Pin to screen (⇧⌘P)'} placement="bottom" wrapperStyle={pinButtonAnchorStyle}>
        <button 
          onClick={handleTogglePin}
          style={{
            ...iconButtonStyle,
            opacity: isPinned ? 1 : 0.3,
            background: isPinned ? 'rgba(255, 255, 255, 0.12)' : 'rgba(255, 255, 255, 0.05)',
            transition: 'all 0.25s cubic-bezier(0.34, 1.56, 0.64, 1)',
          }}
          onMouseEnter={(e) => {
            e.currentTarget.style.opacity = '1';
            e.currentTarget.style.transform = 'scale(1.05)';
          }}
          onMouseLeave={(e) => {
            e.currentTarget.style.opacity = isPinned ? '1' : '0.3';
            e.currentTarget.style.transform = 'scale(1)';
          }}
        >
          <svg 
            width="16" 
            height="16" 
            viewBox="0 0 24 24" 
            fill={isPinned ? "currentColor" : "none"}
            stroke="currentColor" 
            strokeWidth="2" 
            strokeLinecap="round" 
            strokeLinejoin="round"
            style={{
              transform: isPinned ? 'rotate(45deg)' : 'rotate(0deg)',
              transition: 'transform 0.3s cubic-bezier(0.34, 1.56, 0.64, 1)',
            }}
          >
            <line x1="12" y1="17" x2="12" y2="22"/>
            <path d="M5 17h14v-1.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V6h1a2 2 0 0 0 0-4H8a2 2 0 0 0 0 4h1v4.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24Z"/>
          </svg>
        </button>
      </Tooltip>

      {/* Settings Button */}
      <Tooltip label="Settings" placement="bottom" wrapperStyle={settingsButtonAnchorStyle}>
        <button 
          onClick={() => setShowSettings(true)}
          style={iconButtonStyle}
          onMouseEnter={(e) => (e.currentTarget.style.opacity = '1')}
          onMouseLeave={(e) => (e.currentTarget.style.opacity = '0.4')}
        >
          <svg width="18" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="3" />
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z" />
          </svg>
        </button>
      </Tooltip>

      <main style={{ 
        flex: 1, 
        display: 'flex', 
        flexDirection: 'column', 
        alignItems: 'center',
        justifyContent: 'flex-start', 
        width: '100%',
        zIndex: 1,
        padding: '40px 0 0 0',
        minHeight: 0, 
        overflow: 'hidden', 
      }}>
        {/* Timer Section */}
        <div style={{ marginBottom: '4px' }}>
          <TimerView />
        </div>
        
        {/* Task & Controls Stack */}
        <div style={{ 
          display: 'flex', 
          flexDirection: 'column', 
          alignItems: 'center', 
          width: '100%', 
          gap: '16px',
          paddingBottom: '48px'
        }}>
          {/* Active Task Label */}
          <button 
            onClick={() => !showTasks && setShowTasks(true)}
            style={{
              background: 'none',
              border: 'none',
              cursor: showTasks ? 'default' : 'pointer',
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              gap: '8px',
              transition: 'all 0.2s ease',
              pointerEvents: showTasks ? 'none' : 'auto',
              opacity: showTasks ? 0 : 1,
              width: '100%',
              marginTop: '12px',
              maxWidth: '300px',
              padding: '0 24px',
              boxSizing: 'border-box'
            }}
            onMouseEnter={e => { if (!showTasks) e.currentTarget.style.transform = 'translateY(-2px)' }}
            onMouseLeave={e => { if (!showTasks) e.currentTarget.style.transform = 'translateY(0)' }}
          >
            <div 
              style={{ 
                display: 'flex', 
                flexDirection: 'row',
                alignItems: 'center', 
                justifyContent: 'center', 
                gap: '10px',
                width: '100%',
                minWidth: 0,
                flexWrap: 'wrap',
                padding: '6px 16px',
                borderRadius: '12px',
                background: (tasks.length === 0 || !activeTask) ? 'rgba(255, 255, 255, 0.04)' : 'none',
                color: 'white',
                transition: 'all 0.3s ease',
                border: (tasks.length === 0 || !activeTask) ? '1px solid rgba(255, 255, 255, 0.05)' : 'none',
                boxShadow: 'none'
              }}
            >
              {!activeTask && (
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" style={{ opacity: 0.4, color: 'white' }}>
                  <circle cx="12" cy="12" r="10"></circle>
                  <line x1="12" y1="8" x2="12" y2="16"></line>
                  <line x1="8" y1="12" x2="16" y2="12"></line>
                </svg>
              )}
              {activeTask?.title ? (
                <Tooltip label={activeTask.title} maxWidth={280} multiline>
                  <span 
                    style={{ 
                  fontSize: '14px', 
                  fontWeight: '500', 
                  color: activeTask ? 'white' : 'rgba(255, 255, 255, 0.4)',
                  textAlign: 'center',
                  display: '-webkit-box',
                  WebkitLineClamp: activeTask?.tag ? 1 : 2, // Clamp to 1 line if tag exists to save space
                  WebkitBoxOrient: 'vertical',
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  letterSpacing: '0.01em',
                  flexShrink: 1,
                  minWidth: '50px',
                  lineHeight: '1.4',
                  fontFamily: theme.fonts.brand
                    }}
                  >
                    {activeTask.title}
                  </span>
                </Tooltip>
              ) : (
                <span 
                  style={{ 
                    fontSize: '14px', 
                    fontWeight: '500', 
                    color: 'rgba(255, 255, 255, 0.4)',
                    textAlign: 'center',
                    display: '-webkit-box',
                    WebkitLineClamp: 2,
                    WebkitBoxOrient: 'vertical',
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    letterSpacing: '0.01em',
                    flexShrink: 1,
                    minWidth: '50px',
                    lineHeight: '1.4',
                    fontFamily: theme.fonts.brand
                  }}
                >
                  What are you working on?
                </span>
              )}
              {activeTask?.tag && (
                <Tooltip label={activeTask.tag}>
                  <span 
                    style={{ 
                    fontSize: '9px', 
                    fontWeight: '800', 
                    color: theme.colors.focus.primary,
                    background: theme.colors.focus.glow,
                    padding: '2px 8px',
                    borderRadius: '5px',
                    textTransform: 'uppercase',
                    letterSpacing: '0.08em',
                    whiteSpace: 'nowrap',
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    maxWidth: '120px',
                    flexShrink: 0,
                    lineHeight: '1.4',
                    marginTop: '1px'
                  }}
                  >
                    {activeTask.tag}
                  </span>
                </Tooltip>
              )}
            </div>
          {activeTask && (
            <div style={{ display: 'flex', gap: '6px', flexWrap: 'wrap', justifyContent: 'center', alignItems: 'center' }}>
              <div style={{ display: 'flex', gap: '5px', flexWrap: 'wrap', justifyContent: 'center', maxWidth: '240px' }}>
                {Array.from({ length: Math.min(Math.max(activeTask.estimatedPomos, activeTask.completedPomos), 20) }).map((_, i) => (
                  <div 
                    key={i}
                    style={{
                      width: '5px',
                      height: '5px',
                      borderRadius: '50%',
                      background: i < activeTask.completedPomos 
                        ? (i >= activeTask.estimatedPomos ? '#FF9500' : 'white') 
                        : 'rgba(255, 255, 255, 0.12)',
                      transition: 'all 0.3s ease'
                    }}
                  />
                ))}
                {Math.max(activeTask.estimatedPomos, activeTask.completedPomos) > 20 && (
                  <span style={{ fontSize: '8px', color: 'rgba(255,255,255,0.3)', fontWeight: '700' }}>+</span>
                )}
              </div>
              <span style={{ 
                fontSize: '10px', 
                fontWeight: '700', 
                color: 'white', 
                opacity: 0.3, 
                fontFamily: theme.fonts.display,
                fontVariantNumeric: 'tabular-nums'
              }}>
                {activeTask.completedPomos}/{activeTask.estimatedPomos}
              </span>
            </div>
          )}
          </button>

          <Controls />
        </div>
      </main>

      <Tooltip
        label={
          sessionType === 'longBreak'
            ? `Long break – ${config.sessionsUntilLongBreak} focus sessions until next long break`
            : `${focusInCycleCount} of ${config.sessionsUntilLongBreak} focus sessions completed before long break`
        }
        multiline
        maxWidth={260}
        placement="top"
        wrapperStyle={{ display: 'flex', justifyContent: 'center', width: '100%', flexShrink: 0 }}
      >
        <div 
          style={{ 
            display: 'flex', 
            justifyContent: 'center',
            gap: '6px', 
            opacity: 0.3,
            paddingBottom: '16px', 
            cursor: 'default',
          }}
        >
        {Array.from({ length: config.sessionsUntilLongBreak }).map((_, i) => (
          <div 
            key={i}
            style={{
              width: '10px',
              height: '2px',
              borderRadius: '1px',
              backgroundColor: i < focusInCycleCount 
                ? 'rgba(255, 255, 255, 0.8)' 
                : 'rgba(255, 255, 255, 0.1)',
              transition: 'all 0.6s cubic-bezier(0.4, 0, 0.2, 1)'
            }}
          />
        ))}
        </div>
      </Tooltip>

      <TaskShelf isOpen={showTasks} onClose={handleCloseTasks} />
      {showSettings && <SettingsView onClose={() => setShowSettings(false)} />}
      {showReports && <ReportsView onClose={() => setShowReports(false)} />}
      {visibleProposal && (
        <AgentProposalOverlay
          key={visibleProposal.requestId}
          proposal={visibleProposal}
          phase={visibleProposal.phase}
          error={visibleProposal.error}
          queuedCount={agentProposals.length - 1}
          onApproving={handleProposalApproving}
          onDismiss={handleProposalDismiss}
        />
      )}
      {dragHandleTooltip && (
        <FloatingTooltip
          label="Drag to move window"
          x={dragHandleTooltip.x}
          y={dragHandleTooltip.y}
          placement="bottom"
        />
      )}
    </div>
  );
};

const iconButtonStyle: React.CSSProperties = {
  width: '32px',
  height: '32px',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  borderRadius: '50%',
  backgroundColor: 'rgba(255, 255, 255, 0.05)',
  color: 'white',
  opacity: 0.3,
  cursor: 'pointer',
  transition: 'all 0.2s ease-out',
  border: 'none',
  padding: 0,
};

const reportsButtonAnchorStyle: React.CSSProperties = {
  position: 'absolute',
  top: '24px',
  left: '24px',
  zIndex: 10,
};

const pinButtonAnchorStyle: React.CSSProperties = {
  position: 'absolute',
  top: '24px',
  right: '64px',
  zIndex: 10,
};

const settingsButtonAnchorStyle: React.CSSProperties = {
  position: 'absolute',
  top: '24px',
  right: '24px',
  zIndex: 10,
};

export default App;
