`timescale 1ns / 1ps

// ROM com os pesos do filtro, carregada uma vez a partir de um .hex.
module memoria_pesos #(
    parameter int LARGURA_DADO = 32,
    parameter int PROFUNDIDADE = 1024,
    // Default so para sintese: na simulacao o caminho vem por +PESOS=
    parameter string ARQUIVO_PESOS = "pesos.hex"
)(
    input  logic                            clk,
    input  logic [$clog2(PROFUNDIDADE)-1:0] endereco,
    output logic [LARGURA_DADO-1:0]         dado_saida
);

    logic [LARGURA_DADO-1:0] rom [0:PROFUNDIDADE-1];

    // Caminho por +PESOS=, senao o $readmemh resolveria relativo ao cwd
    string arquivo_pesos;
    initial begin
        if (!$value$plusargs("PESOS=%s", arquivo_pesos)) begin
            arquivo_pesos = ARQUIVO_PESOS;
        end
        $readmemh(arquivo_pesos, rom);
    end

    always_ff @(posedge clk) begin
        dado_saida <= rom[endereco];
    end

endmodule
