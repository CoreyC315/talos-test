import { useCallback, useEffect, useRef, useState } from 'react';

const styles = {
  page: {
    minHeight: '100vh',
    background: '#0d1117',
    color: '#e6edf3',
    fontFamily: "'Segoe UI', system-ui, -apple-system, sans-serif",
    padding: '2rem',
    boxSizing: 'border-box',
  },
  container: { maxWidth: 960, margin: '0 auto' },
  title: { fontSize: '1.9rem', fontWeight: 700, margin: 0, letterSpacing: '-0.02em' },
  subtitle: { color: '#8b949e', margin: '0.25rem 0 1.5rem', fontSize: '0.95rem' },
  banner: {
    background: '#3d1d1f',
    border: '1px solid #f85149',
    color: '#ffa198',
    borderRadius: 8,
    padding: '0.6rem 1rem',
    marginBottom: '1rem',
    fontSize: '0.9rem',
  },
  cardsRow: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))',
    gap: '0.9rem',
    marginBottom: '1.5rem',
  },
  card: {
    background: '#161b22',
    border: '1px solid #30363d',
    borderRadius: 10,
    padding: '0.9rem 1.1rem',
  },
  cardLabel: {
    color: '#8b949e',
    fontSize: '0.72rem',
    textTransform: 'uppercase',
    letterSpacing: '0.08em',
    marginBottom: '0.35rem',
  },
  cardValue: { fontSize: '1.35rem', fontWeight: 600, wordBreak: 'break-all' },
  section: {
    background: '#161b22',
    border: '1px solid #30363d',
    borderRadius: 10,
    padding: '1.1rem 1.25rem',
    marginBottom: '1.25rem',
  },
  sectionTitle: { margin: '0 0 0.8rem', fontSize: '1.05rem', fontWeight: 600 },
  input: {
    background: '#0d1117',
    border: '1px solid #30363d',
    color: '#e6edf3',
    borderRadius: 6,
    padding: '0.5rem 0.75rem',
    fontSize: '0.95rem',
    flex: 1,
    outline: 'none',
  },
  button: {
    background: '#238636',
    border: '1px solid rgba(240,246,252,0.1)',
    color: '#fff',
    borderRadius: 6,
    padding: '0.5rem 1rem',
    fontSize: '0.9rem',
    fontWeight: 600,
    cursor: 'pointer',
  },
  buttonAlt: {
    background: '#1f6feb',
    border: '1px solid rgba(240,246,252,0.1)',
    color: '#fff',
    borderRadius: 6,
    padding: '0.5rem 1rem',
    fontSize: '0.9rem',
    fontWeight: 600,
    cursor: 'pointer',
  },
  buttonWarn: {
    background: '#9e6a03',
    border: '1px solid rgba(240,246,252,0.1)',
    color: '#fff',
    borderRadius: 6,
    padding: '0.5rem 1rem',
    fontSize: '0.9rem',
    fontWeight: 600,
    cursor: 'pointer',
  },
  badgeHit: {
    background: '#1c4428',
    color: '#3fb950',
    borderRadius: 999,
    padding: '0.15rem 0.6rem',
    fontSize: '0.72rem',
    fontWeight: 700,
    marginLeft: '0.6rem',
    verticalAlign: 'middle',
  },
  badgeMiss: {
    background: '#3d2300',
    color: '#d29922',
    borderRadius: 999,
    padding: '0.15rem 0.6rem',
    fontSize: '0.72rem',
    fontWeight: 700,
    marginLeft: '0.6rem',
    verticalAlign: 'middle',
  },
  list: { listStyle: 'none', margin: 0, padding: 0 },
  listItem: {
    display: 'flex',
    justifyContent: 'space-between',
    padding: '0.45rem 0.25rem',
    borderBottom: '1px solid #21262d',
    fontSize: '0.92rem',
  },
  muted: { color: '#8b949e', fontSize: '0.82rem' },
  statusLine: { color: '#8b949e', fontSize: '0.85rem', marginTop: '0.6rem' },
};

async function api(path, options) {
  const res = await fetch(path, options);
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`;
    try {
      const body = await res.json();
      if (body && body.error) detail = `${res.status}: ${body.error}`;
    } catch {
      /* not JSON */
    }
    throw new Error(`${path} failed (${detail})`);
  }
  return res;
}

export default function App() {
  const [items, setItems] = useState([]);
  const [cacheStatus, setCacheStatus] = useState(null);
  const [stats, setStats] = useState(null);
  const [name, setName] = useState('');
  const [error, setError] = useState(null);
  const [busyMsg, setBusyMsg] = useState(null);
  const errorTimer = useRef(null);

  const showError = useCallback((err) => {
    setError(String(err.message || err));
    if (errorTimer.current) clearTimeout(errorTimer.current);
    errorTimer.current = setTimeout(() => setError(null), 6000);
  }, []);

  const loadItems = useCallback(async () => {
    try {
      const res = await api('/api/items');
      setCacheStatus(res.headers.get('X-Cache'));
      const body = await res.json();
      setItems(body.items || []);
    } catch (err) {
      showError(err);
    }
  }, [showError]);

  const loadStats = useCallback(async () => {
    try {
      const res = await api('/api/stats');
      setStats(await res.json());
    } catch (err) {
      showError(err);
    }
  }, [showError]);

  useEffect(() => {
    loadItems();
    loadStats();
    const id = setInterval(loadStats, 5000);
    return () => {
      clearInterval(id);
      if (errorTimer.current) clearTimeout(errorTimer.current);
    };
  }, [loadItems, loadStats]);

  const addItem = async (e) => {
    e.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return;
    try {
      await api('/api/items', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name: trimmed }),
      });
      setName('');
      await Promise.all([loadItems(), loadStats()]);
    } catch (err) {
      showError(err);
    }
  };

  const generateLoad = async (n) => {
    setBusyMsg(`Firing ${n} parallel load request${n > 1 ? 's' : ''} (400ms CPU each)...`);
    try {
      const calls = Array.from({ length: n }, () =>
        api('/api/load?ms=400', { method: 'POST' })
      );
      const results = await Promise.allSettled(calls);
      const failed = results.filter((r) => r.status === 'rejected').length;
      setBusyMsg(
        failed === 0
          ? `Done: ${n} load request${n > 1 ? 's' : ''} completed.`
          : `Done: ${n - failed}/${n} succeeded, ${failed} failed.`
      );
      if (failed > 0) showError(results.find((r) => r.status === 'rejected').reason);
    } catch (err) {
      setBusyMsg(null);
      showError(err);
    }
  };

  const queueJobs = async (count) => {
    setBusyMsg(`Queueing ${count} jobs...`);
    try {
      for (let i = 0; i < count; i++) {
        await api('/api/items', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: `bulk-job-${Date.now()}-${i + 1}` }),
        });
        if ((i + 1) % 20 === 0) setBusyMsg(`Queueing jobs... ${i + 1}/${count}`);
      }
      setBusyMsg(`Done: queued ${count} jobs for the worker.`);
      await Promise.all([loadItems(), loadStats()]);
    } catch (err) {
      setBusyMsg(null);
      showError(err);
    }
  };

  return (
    <div style={styles.page}>
      <div style={styles.container}>
        <h1 style={styles.title}>KubeShowcase</h1>
        <p style={styles.subtitle}>
          Tiny production-grade demo: Go API + Redis queue worker + Postgres, observed end to end.
        </p>

        {error && <div style={styles.banner}>API error: {error}</div>}

        <div style={styles.cardsRow}>
          <div style={styles.card}>
            <div style={styles.cardLabel}>Serving pod</div>
            <div style={styles.cardValue}>{stats ? stats.pod : '...'}</div>
            <div style={styles.muted}>you are being served by this pod</div>
          </div>
          <div style={styles.card}>
            <div style={styles.cardLabel}>Items</div>
            <div style={styles.cardValue}>{stats ? stats.item_count : '...'}</div>
          </div>
          <div style={styles.card}>
            <div style={styles.cardLabel}>Queue depth</div>
            <div style={styles.cardValue}>{stats ? stats.queue_depth : '...'}</div>
          </div>
          <div style={styles.card}>
            <div style={styles.cardLabel}>Version</div>
            <div style={styles.cardValue}>{stats ? stats.version : '...'}</div>
            <div style={styles.muted}>
              {stats ? `up ${stats.uptime_seconds}s` : ''}
            </div>
          </div>
        </div>

        <div style={styles.section}>
          <h2 style={styles.sectionTitle}>Demo controls</h2>
          <div style={{ display: 'flex', gap: '0.6rem', flexWrap: 'wrap' }}>
            <button style={styles.buttonAlt} onClick={() => generateLoad(1)}>
              Generate Load ×1
            </button>
            <button style={styles.buttonAlt} onClick={() => generateLoad(10)}>
              Generate Load ×10
            </button>
            <button style={styles.buttonAlt} onClick={() => generateLoad(50)}>
              Generate Load ×50
            </button>
            <button style={styles.buttonWarn} onClick={() => queueJobs(100)}>
              Queue 100 jobs
            </button>
          </div>
          <div style={styles.muted}>
            Load buttons drive the HPA demo (parallel POST /api/load?ms=400); queueing jobs drives
            the KEDA worker-scaling demo.
          </div>
          {busyMsg && <div style={styles.statusLine}>{busyMsg}</div>}
        </div>

        <div style={styles.section}>
          <h2 style={styles.sectionTitle}>Add item</h2>
          <form onSubmit={addItem} style={{ display: 'flex', gap: '0.6rem' }}>
            <input
              style={styles.input}
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Item name"
              maxLength={255}
            />
            <button style={styles.button} type="submit">
              Add
            </button>
          </form>
        </div>

        <div style={styles.section}>
          <h2 style={styles.sectionTitle}>
            Latest items
            {cacheStatus && (
              <span style={cacheStatus === 'hit' ? styles.badgeHit : styles.badgeMiss}>
                cache {cacheStatus}
              </span>
            )}
            <button
              style={{ ...styles.buttonAlt, marginLeft: '0.8rem', padding: '0.25rem 0.7rem', fontSize: '0.78rem' }}
              onClick={loadItems}
              type="button"
            >
              Refresh
            </button>
          </h2>
          {items.length === 0 ? (
            <div style={styles.muted}>No items yet. Add one above.</div>
          ) : (
            <ul style={styles.list}>
              {items.map((it) => (
                <li key={it.id} style={styles.listItem}>
                  <span>
                    <span style={styles.muted}>#{it.id}</span> {it.name}
                  </span>
                  <span style={styles.muted}>
                    {new Date(it.created_at).toLocaleString()}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
