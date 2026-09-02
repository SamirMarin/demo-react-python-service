output "cluster_name" {
  value = module.ecs_service.cluster_name
}

output "service_name" {
  value = module.ecs_service.service_name
}

output "task_definition_arn" {
  value = module.ecs_service.task_definition_arn
}
