import { useSuspenseQuery } from "@tanstack/react-query"
import { createFileRoute } from "@tanstack/react-router"
import { Suspense } from "react"

import { MetricsService } from "@/client"
import Forbidden from "@/components/Common/Forbidden"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Skeleton } from "@/components/ui/skeleton"
import useAuth from "@/hooks/useAuth"
import { can } from "@/lib/permissions"

function getMetricsQueryOptions() {
  return {
    queryFn: async () => (await MetricsService.readMetrics()).data,
    queryKey: ["metrics"],
  }
}

export const Route = createFileRoute("/_layout/metrics")({
  component: Metrics,
  head: () => ({
    meta: [
      {
        title: "Metrics - FastAPI Template",
      },
    ],
  }),
})

function MetricsContent() {
  const { data: metrics } = useSuspenseQuery(getMetricsQueryOptions())

  const stats = [
    { label: "Total users", value: metrics.total_users },
    { label: "Total items", value: metrics.total_items },
  ]

  return (
    <div className="grid gap-4 sm:grid-cols-2">
      {stats.map((stat) => (
        <Card key={stat.label}>
          <CardHeader>
            <CardTitle>{stat.label}</CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-3xl font-bold">{stat.value}</p>
          </CardContent>
        </Card>
      ))}
    </div>
  )
}

function MetricsPage() {
  return (
    <Suspense
      fallback={
        <div className="grid gap-4 sm:grid-cols-2">
          {Array.from({ length: 2 }).map((_, index) => (
            <Card key={index}>
              <CardHeader>
                <Skeleton className="h-4 w-28" />
              </CardHeader>
              <CardContent>
                <Skeleton className="h-8 w-16" />
              </CardContent>
            </Card>
          ))}
        </div>
      }
    >
      <MetricsContent />
    </Suspense>
  )
}

function Metrics() {
  const { user: currentUser } = useAuth()

  if (!can(currentUser, "metrics.view")) {
    return <Forbidden />
  }

  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Metrics</h1>
        <p className="text-muted-foreground">Platform insights and usage</p>
      </div>
      <MetricsPage />
    </div>
  )
}
