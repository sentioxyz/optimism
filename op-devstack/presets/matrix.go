package presets

import (
	"github.com/ethereum-optimism/optimism/op-devstack/devtest"
	"github.com/ethereum-optimism/optimism/op-devstack/sysgo"
)

func RunCLAndELMatrix(t devtest.T, fn func(t devtest.T, opt Option)) {
	RunCLMatrix(t, func(t devtest.T, clOpt Option) {
		RunELMatrix(t, func(t devtest.T, elOpt Option) {
			fn(t, Combine(clOpt, elOpt))
		})
	})
}

func RunELMatrix(t devtest.T, fn func(t devtest.T, opt Option)) {
	for name, opt := range map[string]Option{
		"op-reth": nil,
		"op-geth": nil,
	} {
		t.Run(name, func(t devtest.T) {
			fn(t, opt)
		})
	}
}

func RunCLMatrix(t devtest.T, fn func(t devtest.T, opts Option)) {
	for name, opt := range map[string]Option{
		"op-node":   WithGlobalL2CLOption(sysgo.L2CLOptionFn(sysgo.WithAlwaysOpNode)),
		"kona-node": WithGlobalL2CLOption(sysgo.L2CLOptionFn(sysgo.WithAlwaysKonaNode)),
	} {
		t.Run(name, func(t devtest.T) {
			fn(t, opt)
		})
	}
}
