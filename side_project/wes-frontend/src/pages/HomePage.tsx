import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'

export default function HomePage() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-3xl flex-col justify-center px-5 py-12 text-left sm:px-8">
      <h1 className="max-w-2xl text-3xl font-semibold leading-tight text-slate-900 sm:text-4xl">유방암 소인 Germline 변이 분석</h1>
      <p className="mt-3 max-w-2xl text-sm leading-6 text-muted-foreground sm:text-base">
        Illumina WES 데이터를 업로드하면 BRCA1/2 등 8개 유전자의 변이를 자동 분석합니다.
      </p>
      <Button render={<Link to="/submit" />} className="mt-6 w-fit">
        분석 시작
      </Button>
    </main>
  )
}
