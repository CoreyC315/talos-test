// k6 load profile for the HPA + KEDA demo.
// Ramps API traffic (CPU + custom metric -> HPA) and queues jobs (Redis list -> KEDA).
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'https://app.192.168.1.27.nip.io';

export const options = {
  insecureSkipTLSVerify: true, // homelab CA
  scenarios: {
    api_ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 20 },
        { duration: '5m', target: 60 },
        { duration: '3m', target: 60 },
        { duration: '2m', target: 0 },
      ],
    },
    job_burst: {
      executor: 'per-vu-iterations',
      vus: 5,
      iterations: 40,
      startTime: '4m', // mid-ramp: KEDA wakes the worker from zero
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<1500'],
  },
};

export default function () {
  const r1 = http.get(`${BASE}/api/items`);
  check(r1, { 'items 200': (r) => r.status === 200 });
  const r2 = http.post(`${BASE}/api/load?ms=300`);
  check(r2, { 'load 200': (r) => r.status === 200 });
  sleep(0.5);
}

export function jobBurst() {}
// job_burst scenario shares default(): POSTing items also LPUSHes worker jobs.
