window.rubyc = {
    focusTab: (id) => document.getElementById(id)?.focus({ preventScroll: true }),
    copy: async (text) => {
        try { await navigator.clipboard.writeText(text); return true; }
        catch { return false; }
    }
};

document.addEventListener('keydown', (event) => {
    if (event.target.matches('[role="tab"]') && ['ArrowRight', 'ArrowLeft', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) event.preventDefault();
});
