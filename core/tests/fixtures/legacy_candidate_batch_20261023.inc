// Exact pre-budget loader retained only as a behavioral comparison oracle.
// Not linked by any product target.
size_t legacy_batch_oracle(PI_Session id, size_t offset, size_t limit) {
  std::lock_guard<std::recursive_mutex> lock(gate);
  if (!api || !sessions.count(id) || offset > 100000 || limit == 0 || limit > 128) return 0;
  auto &s = sessions.at(id); s.batch.clear();
  const auto input_reading = s.nine_key ? nine_reading(s.active_reading) : normalized_reading(s.active_reading);
  std::set<std::string> pinned;
  if (!s.private_mode) for (const auto &p : pinned_words)
    if (!input_reading.empty()) {
      const auto code = s.nine_key ? nine_reading(p.first) : p.first;
      if (code.compare(0, input_reading.size(), input_reading) == 0 || input_reading.compare(0, code.size(), code) == 0) pinned.insert(p.second);
    }
  // Build an incrementally cached logical stream of admitted rows. Offsets
  // refer to visible rows, while selection retains original native indices.
  // Filtering cannot duplicate/skip a later page or hide all valid rows behind
  // a native page made entirely of obsolete traditional/rare user entries.
  if (!s.ranked_ready) {
    if (!pinned.empty()) {
      RimeCandidateListIterator all{};
      if (api->candidate_list_begin(id, &all)) {
        while (!pinned.empty() && api->candidate_list_next(&all)) {
          if (all.index < 0) break;
          const std::string text = all.candidate.text ? all.candidate.text : "";
          if (pinned.erase(text) && private_input::mainland::candidate_allowed(text))
            s.ranked.push_back({text, all.candidate.comment ? all.candidate.comment : "", static_cast<size_t>(all.index)});
        }
        api->candidate_list_end(&all);
      }
    }
    if(s.nine_key && *pi_nine_preferred_reading(id)){
      std::set<size_t> existing;for(const auto &row:s.ranked)existing.insert(row.index);
      std::vector<StreamCandidate> compatible[2];RimeCandidateListIterator rows{};
      if(api->candidate_list_begin(id,&rows)){
        for(size_t n=0;n<128&&api->candidate_list_next(&rows);++n){
          const std::string text=rows.candidate.text?rows.candidate.text:"",reading=rows.candidate.comment?rows.candidate.comment:"";
          const auto priority=pi_nine_candidate_path_priority(id,reading.c_str());
          if(priority<2&&rows.index>=0&&!existing.count(size_t(rows.index))&&private_input::mainland::candidate_allowed(text))compatible[priority].push_back({text,reading,size_t(rows.index)});
        }api->candidate_list_end(&rows);
      }
      for(auto &group:compatible)s.ranked.insert(s.ranked.end(),group.begin(),group.end());
    }
    s.admitted = s.ranked; s.ranked_ready = true;
  }
  if (s.admitted.size() < offset + limit && !s.admitted_end) {
    std::set<size_t> promoted;
    for (const auto &row : s.ranked) promoted.insert(row.index);
    RimeCandidateListIterator iterator{};
    if (api->candidate_list_from_index(id, &iterator, static_cast<int>(s.admitted_cursor))) {
      while (s.admitted.size() < offset + limit) {
        if (!api->candidate_list_next(&iterator) || iterator.index < 0) { s.admitted_end = true; break; }
        const auto native_index = static_cast<size_t>(iterator.index);
        s.admitted_cursor = native_index + 1;
        const std::string text = iterator.candidate.text ? iterator.candidate.text : "";
        if (!promoted.count(native_index) && private_input::mainland::candidate_allowed(text))
          s.admitted.push_back({text, iterator.candidate.comment ? iterator.candidate.comment : "", native_index});
      }
      api->candidate_list_end(&iterator);
    } else s.admitted_end = true;
  }
  for (size_t i = offset; i < s.admitted.size() && s.batch.size() < limit; ++i) s.batch.push_back(s.admitted[i]);
  const auto reading = s.nine_key ? nine_reading(s.active_reading) : normalized_reading(s.active_reading);
  std::map<std::string, unsigned long long> scores;
  if (!s.private_mode) for (const auto &p : preferences) if ((s.nine_key ? nine_reading(p.first.first) : p.first.first) == reading) scores[p.first.second] = std::max(scores[p.first.second], p.second);
  auto score = [&](const StreamCandidate &c) { auto p = scores.find(c.text); return p == scores.end() ? 0ULL : p->second; };
  std::stable_sort(s.batch.begin(), s.batch.end(), [&](const auto &a, const auto &b) { const bool ap = std::any_of(s.ranked.begin(), s.ranked.end(), [&](const auto &row) { return row.index == a.index; }); const bool bp = std::any_of(s.ranked.begin(), s.ranked.end(), [&](const auto &row) { return row.index == b.index; }); if (ap != bp) return ap; return score(a) > score(b); });
  return s.batch.size();
}
