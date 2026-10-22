#pragma once
#include <memory>
namespace private_input {
// Model/publication updates wait for a fresh composition. Revocation and scope
// changes fall back immediately to the independent legacy snapshot; a newly
// authorized cloud model still waits for idle before it can become active.
template<class T>std::shared_ptr<const T> freezeLearningSnapshot(std::shared_ptr<const T>current,std::shared_ptr<const T>held,bool idle){if(idle||!held)return current;if(!held->scopeGeneration)return held;if(current->scopeGeneration!=held->scopeGeneration)return current->cloudActive&&current->fallback?current->fallback:current;if(held->cloudActive&&(!current->cloudActive||current->cloudToken!=held->cloudToken))return current->cloudActive&&current->fallback?current->fallback:current;return held;}
}
