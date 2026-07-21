package tabsnapshot

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

func (store *Store) PlanRetention() (RetentionPlan, error) {
	items, err := store.List()
	if err != nil {
		return RetentionPlan{}, err
	}
	if len(items) == 0 {
		return RetentionPlan{}, nil
	}
	if !items[0].Valid {
		return RetentionPlan{}, errors.New("retention refused: newest generation is invalid")
	}

	keep := map[string]struct{}{items[0].Manifest.Generation: {}}
	for _, item := range items {
		if !item.Valid || item.Manifest.Protected {
			keep[item.Manifest.Generation] = struct{}{}
		}
	}
	selectBuckets(items, keep, 24, func(value time.Time) string {
		return value.UTC().Format("2006-01-02T15")
	})
	selectBuckets(items, keep, 14, func(value time.Time) string {
		return value.UTC().Format("2006-01-02")
	})
	selectBuckets(items, keep, 12, func(value time.Time) string {
		year, week := value.UTC().ISOWeek()
		return fmt.Sprintf("%04d-W%02d", year, week)
	})

	var plan RetentionPlan
	for _, item := range items {
		generation := item.Manifest.Generation
		if _, ok := keep[generation]; ok {
			plan.Keep = append(plan.Keep, generation)
		} else if item.Valid {
			plan.Delete = append(plan.Delete, generation)
		}
	}
	sort.Strings(plan.Keep)
	sort.Strings(plan.Delete)
	return plan, nil
}

func (store *Store) ApplyRetention(plan RetentionPlan) error {
	current, err := store.PlanRetention()
	if err != nil {
		return err
	}
	allowed := make(map[string]struct{}, len(current.Delete))
	for _, generation := range current.Delete {
		allowed[generation] = struct{}{}
	}
	for _, generation := range plan.Delete {
		if _, ok := allowed[generation]; !ok {
			return fmt.Errorf("retention deletion is no longer safe: %s", generation)
		}
		manifest, err := store.Validate(generation)
		if err != nil {
			return fmt.Errorf("refuse to delete invalid generation %s: %w", generation, err)
		}
		if manifest.Protected {
			return fmt.Errorf("refuse to delete protected generation %s", generation)
		}
	}
	for _, generation := range plan.Delete {
		target := filepath.Join(store.generations, generation)
		if !validGenerationID(generation) || filepath.Dir(target) != store.generations {
			return errors.New("retention target escaped generation directory")
		}
		if err := os.RemoveAll(target); err != nil {
			return fmt.Errorf("delete retained generation %s: %w", generation, err)
		}
	}
	return syncDirectory(store.generations)
}

func selectBuckets(items []Generation, keep map[string]struct{}, limit int, bucket func(time.Time) string) {
	seen := make(map[string]struct{})
	for _, item := range items {
		if !item.Valid {
			continue
		}
		key := bucket(item.Manifest.CapturedAt)
		if _, ok := seen[key]; ok {
			continue
		}
		if len(seen) >= limit {
			break
		}
		seen[key] = struct{}{}
		keep[item.Manifest.Generation] = struct{}{}
	}
}
