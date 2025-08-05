import { Moon, Sun } from 'lucide-react'
import { useState, useEffect } from 'react'

export default function TopBar() {
  const [dark, setDark] = useState(
    window.matchMedia('(prefers-color-scheme: dark)').matches,
  )

  useEffect(() => {
    document.documentElement.classList.toggle('dark', dark)
  }, [dark])

  const toggle = () => setDark(!dark)

  return (
    <header className="topbar flex items-center justify-between px-6 h-12 border-b border-neutral-800 bg-neutral-950 text-neutral-100 dark:bg-neutral-950 dark:border-neutral-800">
      <h1 className="font-semibold tracking-tight text-sm">
        JVT – Incremental Vector Tiles
      </h1>

      <button
        className="p-1 rounded hover:bg-neutral-800 transition-colors"
        onClick={toggle}
        aria-label="Toggle dark mode"
      >
        {dark ? <Sun size={18} /> : <Moon size={18} />}
      </button>
    </header>
  )
}
