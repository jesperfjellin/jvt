export default function SpeedGauge() {
  // placeholder until you wire real numbers
  return (
    <div className="gauge flex flex-col items-center justify-center h-full rounded-xl bg-neutral-800 text-neutral-100">
      <svg width="140" height="140" viewBox="0 0 120 120">
        <circle
          cx="60"
          cy="60"
          r="54"
          stroke="#333"
          strokeWidth="12"
          fill="none"
        />
        <circle
          cx="60"
          cy="60"
          r="54"
          stroke="#22c55e"
          strokeWidth="12"
          fill="none"
          strokeDasharray={`${(3277 / 65536) * 339} 999`}
          strokeLinecap="round"
          transform="rotate(-90 60 60)"
        />
      </svg>
      <p className="text-center mt-2 text-sm opacity-80">
        ~1.7 K&nbsp;tiles / sec
      </p>
    </div>
  )
}
