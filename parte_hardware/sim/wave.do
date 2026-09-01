onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate /tb_acelerador/clk
add wave -noupdate /tb_acelerador/rst_n
add wave -noupdate /tb_acelerador/rx
add wave -noupdate /tb_acelerador/tx
add wave -noupdate /tb_acelerador/dut/fio_peso_bram
add wave -noupdate /tb_acelerador/dut/fio_dado_bram
add wave -noupdate /tb_acelerador/dut/fio_dado_32b
add wave -noupdate /tb_acelerador/dut/fio_dado_valido_32b
TreeUpdate [SetDefaultTree]
WaveRestoreCursors {{Cursor 1} {150981114 ps} 0}
quietly wave cursor active 1
configure wave -namecolwidth 246
configure wave -valuecolwidth 406
configure wave -justifyvalue left
configure wave -signalnamewidth 0
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ps
update
WaveRestoreZoom {0 ps} {417270 ns}
